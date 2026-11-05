import EdithExtensionUI
import SwiftUI

struct HostExtensionPreviewScene: View {
    static let ids: Set<String> = [
        "attention", "bifrost", "codeStats", "companion", "database", "docs", "emoji", "hinge",
        "jev", "keepAwake", "latex", "plugins", "seoAudit", "socialManager", "studio", "terminal",
        "timeLapse", "virtualCamera",
    ]

    let id: String
    let symbolName: String
    let dark: Bool
    let phase: Double

    private var accent: Color { DashSkin.accent(dark) }
    private var ink: Color { DashSkin.ink(dark) }
    private var soft: Color { DashSkin.inkSoft(dark) }
    private var faint: Color { DashSkin.inkFaint(dark) }
    private var line: Color { DashSkin.lineStrong(dark) }
    private var pulse: Double { (sin(phase * 2.1) + 1) / 2 }

    var body: some View {
        scene.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var scene: some View {
        switch id {
        case "attention": attention
        case "bifrost": launcher
        case "codeStats": codeStats
        case "companion": memory
        case "database": database
        case "docs": docs
        case "emoji": emoji
        case "hinge": hinge
        case "jev": jev
        case "keepAwake": keepAwake
        case "latex": latex
        case "plugins": plugins
        case "seoAudit": siteAudit
        case "socialManager": socialManager
        case "studio": studio
        case "terminal": terminal
        case "timeLapse": screenRecorder
        case "virtualCamera": virtualCamera
        default: fallback
        }
    }

    private var attention: some View {
        let rows: [(name: String, share: Double, time: String, tint: Double)] = [
            ("Editor", 1, "3h 12m", 1), ("Browser", 0.56, "1h 48m", 0.65),
            ("Messages", 0.24, "46m", 0.4),
        ]
        return VStack(spacing: UIScale.pt(8)) {
            ForEach(rows, id: \.name) { row in
                HStack(spacing: UIScale.pt(8)) {
                    label(row.name, size: 7.5).frame(width: UIScale.pt(40), alignment: .leading)
                    meter(row.share, tint: accent.opacity(row.tint), height: 7)
                    label(row.time, size: 7.5, tint: faint)
                        .frame(width: UIScale.pt(32), alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(16))
    }

    private var launcher: some View {
        VStack(spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(7)) {
                symbol("magnifyingglass", size: 9, tint: faint)
                Text("12 × 8").font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(24))
            .background(DashSkin.paper(dark), in: corners(7))
            .overlay { corners(7).strokeBorder(line) }
            HStack(spacing: UIScale.pt(7)) {
                symbol("equal.circle.fill", size: 10, tint: accent)
                Text("96").font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
                label("Copy", size: 7, tint: accent)
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(20))
            .background(accent.opacity(0.14), in: corners(6))
            HStack(spacing: UIScale.pt(7)) {
                symbol("app.fill", size: 10, tint: faint)
                bar(72, tint: line)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(16))
        }
        .padding(.horizontal, UIScale.pt(14))
    }

    private var codeStats: some View {
        let columns = 24
        let rows = 7
        let cell = UIScale.pt(5.5)
        let gap = UIScale.pt(1.8)
        let tint = accent
        let empty = line.opacity(0.5)
        return Canvas { context, _ in
            for column in 0..<columns {
                for row in 0..<rows {
                    let level = (column * 7 + row * 13 + column * row + column / 3) % 5
                    let growth = Double(column) / Double(columns)
                    let opacity = level == 0 ? 0 : min(1, 0.2 + Double(level) * 0.14 + growth * 0.3)
                    let rect = CGRect(
                        x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap),
                        width: cell, height: cell)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: UIScale.pt(1.2)),
                        with: .color(level == 0 ? empty : tint.opacity(opacity)))
                }
            }
        }
        .frame(
            width: CGFloat(columns) * (cell + gap) - gap, height: CGFloat(rows) * (cell + gap) - gap
        )
    }

    private var memory: some View {
        VStack(spacing: UIScale.pt(7)) {
            HStack {
                Spacer(minLength: 0)
                Text("What did we decide on Friday?")
                    .font(.system(size: UIScale.pt(8), weight: .medium))
                    .foregroundStyle(DashSkin.onAccent(dark))
                    .padding(.horizontal, UIScale.pt(9))
                    .frame(height: UIScale.pt(20))
                    .background(accent, in: corners(9))
            }
            HStack(alignment: .top, spacing: UIScale.pt(8)) {
                symbol("brain.head.profile", size: 15, tint: accent)
                    .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    bar(116, tint: soft.opacity(0.55))
                    bar(92, tint: faint.opacity(0.45))
                }
                .padding(.horizontal, UIScale.pt(9))
                .padding(.vertical, UIScale.pt(8))
                .background(DashSkin.paper(dark), in: corners(9))
                .overlay { corners(9).strokeBorder(line) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, UIScale.pt(14))
    }

    private var database: some View {
        let rows = [
            ["id", "name", "plan"], ["1", "Ada", "pro"], ["2", "Grace", "team"],
            ["3", "Alan", "free"],
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                        label(
                            value, size: index == 0 ? 7 : 8,
                            tint: index == 0 ? faint : (index == 2 ? accent : soft)
                        )
                        .frame(
                            width: UIScale.pt(column == 0 ? 28 : 64), alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, UIScale.pt(9))
                .frame(height: UIScale.pt(16))
                .background(index == 2 ? accent.opacity(0.12) : Color.clear)
                if index == 0 { Rectangle().fill(line).frame(height: UIScale.pt(0.75)) }
            }
        }
        .background(DashSkin.paper(dark))
        .clipShape(corners(7))
        .overlay { corners(7).strokeBorder(line) }
        .padding(.horizontal, UIScale.pt(14))
    }

    private var docs: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack(spacing: UIScale.pt(7)) {
                symbol("magnifyingglass", size: 9, tint: faint)
                Text("trim a video").font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(24))
            .background(DashSkin.paper(dark), in: corners(7))
            .overlay { corners(7).strokeBorder(line) }
            HStack(spacing: UIScale.pt(7)) {
                symbol("return.right", size: 8, tint: accent)
                Text("ed studio edit clip.mov").font(DashSkin.mono(8.5, weight: .medium))
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(24))
            .background(accent.opacity(0.12), in: corners(7))
        }
        .padding(.horizontal, UIScale.pt(16))
    }

    private var emoji: some View {
        let glyphs = ["😀", "🎉", "🚀", "❤️", "👍", "🔥", "😎", "🌈", "✨", "🍕", "🐱", "☕️"]
        let selected = 8
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(UIScale.pt(26)), spacing: UIScale.pt(2)), count: 6),
            spacing: UIScale.pt(2)
        ) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                Text(glyph).font(.system(size: UIScale.pt(16)))
                    .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                    .background(index == selected ? accent.opacity(0.18) : .clear, in: corners(6))
                    .overlay {
                        if index == selected { corners(6).strokeBorder(accent.opacity(0.7)) }
                    }
            }
        }
    }

    private var hinge: some View {
        let width = UIScale.pt(112)
        let lower = accent.opacity(0.8)
        let upper = accent.opacity(0.32)
        return VStack(spacing: 0) {
            HostPreviewTrapezoid(inset: UIScale.pt(16))
                .fill(LinearGradient(colors: [upper, lower], startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: UIScale.pt(26))
            Rectangle().fill(.white.opacity(0.7)).frame(width: width, height: UIScale.pt(1))
            Rectangle().fill(lower).frame(width: width, height: UIScale.pt(24))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: UIScale.pt(4)) {
                        corners(3).fill(.white.opacity(0.85))
                            .frame(width: UIScale.pt(30), height: UIScale.pt(14))
                        corners(3).fill(.white.opacity(0.55))
                            .frame(width: UIScale.pt(44), height: UIScale.pt(14))
                    }
                    .padding(UIScale.pt(5))
                }
            Capsule().fill(line).frame(width: UIScale.pt(132), height: UIScale.pt(5))
        }
    }

    private var jev: some View {
        HStack(spacing: UIScale.pt(7)) {
            label("is this urgent?", size: 8)
                .padding(.horizontal, UIScale.pt(8))
                .frame(height: UIScale.pt(26))
                .background(DashSkin.paper(dark), in: corners(7))
                .overlay { corners(7).strokeBorder(line) }
            symbol("arrow.right", size: 8, tint: faint)
            EdithIconView(.jev, size: UIScale.pt(20)).foregroundStyle(accent)
            symbol("arrow.right", size: 8, tint: faint)
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                label("yes", size: 9, tint: accent)
                label("12 ms", size: 6.5, tint: faint)
            }
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(30))
            .background(accent.opacity(0.12), in: corners(7))
        }
    }

    private var keepAwake: some View {
        HStack(spacing: UIScale.pt(14)) {
            ZStack {
                Circle().stroke(line, lineWidth: UIScale.pt(5))
                Circle().trim(from: 0, to: 0.68)
                    .stroke(accent, style: .init(lineWidth: UIScale.pt(5), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                symbol("sun.max.fill", size: 17, tint: accent)
            }
            .frame(width: UIScale.pt(52), height: UIScale.pt(52))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text("Staying awake").font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(ink)
                label("1h 24m left", size: 8, tint: faint)
            }
        }
    }

    private var latex: some View {
        HStack(spacing: UIScale.pt(8)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                label("\\section{Energy}", size: 7, tint: accent)
                label("\\begin{equation}", size: 7, tint: faint)
                label("  E = mc^2", size: 7, tint: ink)
                label("\\end{equation}", size: 7, tint: faint)
            }
            .padding(.horizontal, UIScale.pt(8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(DashSkin.paper(dark), in: corners(6))
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                bar(48, height: 5, tint: Color.black.opacity(0.7))
                Text("E = mc²")
                    .font(.system(size: UIScale.pt(13), design: .serif).italic())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                bar(64, height: 3, tint: Color.black.opacity(0.22))
                bar(52, height: 3, tint: Color.black.opacity(0.22))
            }
            .padding(.horizontal, UIScale.pt(9))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white, in: corners(4))
            .shadow(color: .black.opacity(0.14), radius: UIScale.pt(2), y: UIScale.pt(1))
        }
        .padding(UIScale.pt(10))
    }

    private var plugins: some View {
        let rows: [(name: String, symbol: String, added: Bool)] = [
            ("Studio", "wand.and.stars", true), ("Music", "music.note", true),
            ("Calendar", "calendar", false),
        ]
        return VStack(spacing: UIScale.pt(4)) {
            ForEach(rows, id: \.name) { row in
                HStack(spacing: UIScale.pt(8)) {
                    symbol(row.symbol, size: 9, tint: accent)
                        .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                        .background(accent.opacity(0.12), in: corners(5))
                    Text(row.name).font(.system(size: UIScale.pt(9), weight: .medium))
                        .foregroundStyle(ink)
                    Spacer(minLength: 0)
                    if row.added {
                        symbol("checkmark.circle.fill", size: 10, tint: DashSkin.sage)
                    } else {
                        Text("Add").font(.system(size: UIScale.pt(8), weight: .semibold))
                            .foregroundStyle(DashSkin.onAccent(dark))
                            .padding(.horizontal, UIScale.pt(8))
                            .frame(height: UIScale.pt(16))
                            .background(accent, in: corners(5))
                    }
                }
            }
        }
        .padding(.horizontal, UIScale.pt(18))
    }

    private var siteAudit: some View {
        let checks: [(name: String, passed: Bool)] = [
            ("Page title", true), ("Meta description", false), ("Headings", true),
        ]
        return HStack(spacing: UIScale.pt(16)) {
            ZStack {
                Circle().stroke(line, lineWidth: UIScale.pt(5))
                Circle().trim(from: 0, to: 0.92)
                    .stroke(DashSkin.sage, style: .init(lineWidth: UIScale.pt(5), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("92").font(.system(size: UIScale.pt(15), weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
            }
            .frame(width: UIScale.pt(52), height: UIScale.pt(52))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(checks, id: \.name) { check in
                    HStack(spacing: UIScale.pt(6)) {
                        symbol(
                            check.passed
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            size: 9, tint: check.passed ? DashSkin.sage : DashSkin.warn)
                        Text(check.name).font(.system(size: UIScale.pt(8.5), weight: .medium))
                            .foregroundStyle(soft)
                    }
                }
            }
        }
    }

    private var socialManager: some View {
        let accounts: [(tint: Color, symbol: String)] = [
            (accent, "person.fill"), (DashSkin.sage, "person.fill"), (DashSkin.warn, "person.fill"),
        ]
        return HStack(spacing: UIScale.pt(8)) {
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                VStack(spacing: UIScale.pt(5)) {
                    symbol(account.symbol, size: 11, tint: .white)
                        .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                        .background(account.tint, in: Circle())
                    bar(34, tint: soft.opacity(0.55))
                    bar(24, height: 3, tint: faint.opacity(0.45))
                    Circle().fill(DashSkin.sage).frame(width: UIScale.pt(5), height: UIScale.pt(5))
                }
                .frame(width: UIScale.pt(52), height: UIScale.pt(70))
                .background(DashSkin.paper(dark), in: corners(8))
                .overlay { corners(8).strokeBorder(line) }
            }
        }
    }

    private var studio: some View {
        let frames = 6
        let travel = CGFloat(0.28 + pulse * 0.42)
        return GeometryReader { proxy in
            let span = proxy.size.width
            VStack(spacing: UIScale.pt(5)) {
                HStack(spacing: UIScale.pt(1.5)) {
                    ForEach(0..<frames, id: \.self) { index in
                        Rectangle().fill(
                            accent.opacity(index == 2 || index == 3 ? 0.85 : 0.42))
                    }
                }
                .frame(height: UIScale.pt(30))
                .clipShape(corners(5))
                HostPreviewWaveform(tint: faint.opacity(0.75))
                    .frame(height: UIScale.pt(20))
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Capsule().fill(ink).frame(width: UIScale.pt(2))
                    .offset(x: span * travel)
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(12))
    }

    private var terminal: some View {
        let green = Color(red: 0.49, green: 0.84, blue: 0.56)
        return VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(4)) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.28))
                        .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, UIScale.pt(3))
            terminalLine("$ ed status", tint: .white)
            terminalLine("  12 extensions running", tint: green)
            HStack(spacing: UIScale.pt(3)) {
                terminalLine("$", tint: .white)
                Rectangle().fill(.white.opacity(0.85))
                    .frame(width: UIScale.pt(5), height: UIScale.pt(10))
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
    }

    private func terminalLine(_ text: String, tint: Color) -> some View {
        Text(text).font(DashSkin.mono(9, weight: .medium)).foregroundStyle(tint)
    }

    private var screenRecorder: some View {
        ZStack {
            HStack(spacing: UIScale.pt(6)) {
                corners(4).fill(line.opacity(0.7))
                    .frame(width: UIScale.pt(62), height: UIScale.pt(38))
                VStack(spacing: UIScale.pt(5)) {
                    corners(3).fill(line.opacity(0.5)).frame(height: UIScale.pt(16))
                    corners(3).fill(accent.opacity(0.3)).frame(height: UIScale.pt(17))
                }
                .frame(width: UIScale.pt(62))
            }
            .frame(width: UIScale.pt(150), height: UIScale.pt(68))
            .background(DashSkin.paper(dark), in: corners(7))
            .overlay { corners(7).strokeBorder(line) }
            VStack {
                HStack {
                    HStack(spacing: UIScale.pt(4)) {
                        Circle().fill(.red).frame(width: UIScale.pt(6), height: UIScale.pt(6))
                        Text("00:42").font(DashSkin.mono(7.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, UIScale.pt(6))
                    .frame(height: UIScale.pt(15))
                    .background(.black.opacity(0.78), in: Capsule())
                    Spacer(minLength: 0)
                    Text("8×").font(DashSkin.mono(7.5, weight: .semibold))
                        .foregroundStyle(DashSkin.onAccent(dark))
                        .padding(.horizontal, UIScale.pt(6))
                        .frame(height: UIScale.pt(15))
                        .background(accent, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(UIScale.pt(6))
            .frame(width: UIScale.pt(150), height: UIScale.pt(68))
        }
    }

    private var virtualCamera: some View {
        let size = CGSize(width: UIScale.pt(124), height: UIScale.pt(72))
        return ZStack {
            LinearGradient(
                colors: [accent.opacity(0.55), accent.opacity(0.18)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            VStack(spacing: UIScale.pt(2)) {
                Circle().fill(.white.opacity(0.92))
                    .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                UnevenRoundedRectangle(
                    topLeadingRadius: UIScale.pt(20), topTrailingRadius: UIScale.pt(20)
                )
                .fill(.white.opacity(0.92))
                .frame(width: UIScale.pt(60), height: UIScale.pt(22))
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            VStack {
                HStack {
                    Text("LIVE").font(DashSkin.mono(6.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, UIScale.pt(5))
                        .frame(height: UIScale.pt(13))
                        .background(.red, in: corners(3))
                    Spacer(minLength: 0)
                    symbol("web.camera.fill", size: 10, tint: .white)
                }
                Spacer(minLength: 0)
            }
            .padding(UIScale.pt(6))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(corners(8))
        .overlay { corners(8).strokeBorder(line) }
    }

    private var fallback: some View {
        HStack(spacing: UIScale.pt(14)) {
            symbol(symbolName, size: 24, tint: accent)
                .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                .background(accent.opacity(0.12), in: corners(12))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                bar(84, height: 6, tint: soft.opacity(0.6))
                bar(112, tint: faint.opacity(0.45))
                bar(68, tint: faint.opacity(0.45))
            }
        }
    }

    private func corners(_ radius: Double) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: UIScale.pt(radius), style: .continuous)
    }

    private func label(_ text: String, size: Double, tint: Color? = nil) -> some View {
        Text(text).font(DashSkin.mono(size, weight: .medium)).foregroundStyle(tint ?? soft)
            .lineLimit(1).fixedSize()
    }

    private func symbol(_ name: String, size: Double, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: UIScale.pt(size), weight: .medium))
            .foregroundStyle(tint)
    }

    private func bar(_ width: Double, height: Double = 4, tint: Color) -> some View {
        Capsule().fill(tint).frame(width: UIScale.pt(width), height: UIScale.pt(height))
    }

    private func meter(_ share: Double, tint: Color, height: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(line.opacity(0.6))
                Capsule().fill(tint).frame(width: proxy.size.width * share)
            }
        }
        .frame(height: UIScale.pt(height))
    }
}

struct HostPreviewTrapezoid: Shape {
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct HostPreviewWaveform: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let bars = 48
            let step = size.width / CGFloat(bars)
            let width = max(1, step * 0.55)
            for index in 0..<bars {
                let wave = (sin(Double(index) * 0.7) + sin(Double(index) * 0.23) + 2) / 4
                let height = max(UIScale.pt(2), size.height * CGFloat(0.2 + wave * 0.8))
                let rect = CGRect(
                    x: CGFloat(index) * step, y: (size.height - height) / 2, width: width,
                    height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(tint))
            }
        }
    }
}
