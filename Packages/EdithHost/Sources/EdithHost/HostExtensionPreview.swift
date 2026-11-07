import AppKit
import EdithHostCore
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HostExtensionPreview: View {
    static let previewIDs: Set<String> = HostExtensionPreviewScene.ids.union([
        "usage", "herdr", "quinjet", "system", "appMaintenance", "machines", "systemStats",
        "micMute", "lidAwake", "calendar", "notchShelf", "clipboard", "keystrokeHighlight",
        "music", "focusDim", "windowSweaters", "presenter", "colorPicker", "homebrew",
        "cleaner", "blitztree", "downloads", "audioMixer",
    ])

    let entry: HostExtension
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowVisible) private var visible
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @State private var hovering = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.standard.rawValue

    var body: some View {
        let animates = HostExtensionPreviewMotionPolicy.animates(
            hovering: hovering && visible && automaticActions, reduceMotion: reduceMotion)
        preview(
            phase: HostExtensionPreviewMotionPolicy.phase(
                for: entry.id, hovering: hovering && visible && automaticActions,
                reduceMotion: reduceMotion),
            animating: animates
        )
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func preview(phase: Double, animating: Bool) -> some View {
        switch entry.id {
        case "usage": usagePreview(phase: phase)
        case "herdr": herdrPreview(phase: phase)
        case "quinjet": quinjetPreview(phase: phase)
        case "system": systemPreview(phase: phase)
        case "appMaintenance": maintenancePreview(phase: phase)
        case "machines": machinesPreview(phase: phase)
        case "systemStats": systemStatsPreview(phase: phase)
        case "micMute": micMutePreview(phase: phase)
        case "lidAwake": lidAwakePreview(phase: phase)
        case "calendar": calendarPreview(phase: phase)
        case "notchShelf": notchPreview(phase: phase)
        case "clipboard": clipboardPreview(phase: phase)
        case "keystrokeHighlight": keystrokeHighlightPreview(phase: phase)
        case "music": musicPreview(animating: animating)
        case "focusDim": focusDimPreview(phase: phase)
        case "windowSweaters": windowSweatersPreview(phase: phase)
        case "presenter": presenterPreview(phase: phase)
        case "colorPicker": colorPickerPreview(phase: phase)
        case "homebrew": homebrewPreview(phase: phase)
        case "cleaner": cleanerPreview(phase: phase)
        case "blitztree": blitzTreePreview
        case "downloads": downloadsPreview(phase: phase)
        case "audioMixer": audioMixerPreview(phase: phase)
        default:
            HostExtensionPreviewScene(
                id: entry.id, icon: HostExtensionIcon.resolve(entry), dark: dark, phase: phase)
        }
    }

    private var blitzTreePreview: some View {
        HStack(spacing: UIScale.pt(3)) {
            RoundedRectangle(cornerRadius: UIScale.pt(4)).fill(.blue.opacity(0.8))
            VStack(spacing: UIScale.pt(3)) {
                RoundedRectangle(cornerRadius: UIScale.pt(4)).fill(.teal.opacity(0.8))
                HStack(spacing: UIScale.pt(3)) {
                    RoundedRectangle(cornerRadius: UIScale.pt(4)).fill(.indigo.opacity(0.8))
                    RoundedRectangle(cornerRadius: UIScale.pt(4)).fill(.orange.opacity(0.8))
                }
            }
        }
        .padding(UIScale.pt(12))
    }

    private func usagePreview(phase: Double) -> some View {
        let session = 0.48 + sin(phase * 1.7) * 0.2
        let week = 0.41
        return VStack(spacing: UIScale.pt(12)) {
            usageMeter("SESSION", fill: session)
            usageMeter("THIS WEEK", fill: week)
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(15))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func usageMeter(_ title: String, fill: Double) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack {
                Text(title)
                    .font(DashSkin.mono(7, weight: .semibold))
                Spacer()
                Text("\(Int(fill * 100))%")
                    .font(DashSkin.mono(8, weight: .medium))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashSkin.lineStrong(dark))
                    Capsule()
                        .fill(DashSkin.accent(dark))
                        .frame(width: proxy.size.width * fill)
                }
            }
            .frame(height: UIScale.pt(7))
        }
    }

    private func herdrPreview(phase: Double) -> some View {
        let pulse = (sin(phase * 2.1) + 1) / 2
        let columns: [(title: String, cards: Int, tint: Color)] = [
            ("RUNNING", 2, DashSkin.accent(dark)), ("NEEDS YOU", 1, DashSkin.warn),
            ("DONE", 2, DashSkin.sage),
        ]
        return HStack(alignment: .top, spacing: UIScale.pt(6)) {
            ForEach(columns, id: \.title) { column in
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(column.title)
                        .font(DashSkin.mono(6, weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    ForEach(0..<column.cards, id: \.self) { index in
                        herdrCard(
                            tint: column.tint,
                            emphasis: column.cards == 1 ? 0.45 + pulse * 0.45 : 0,
                            width: index == 0 ? 36 : 28)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func herdrCard(tint: Color, emphasis: Double, width: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(4), style: .continuous)
        return VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(spacing: UIScale.pt(3)) {
                Circle().fill(tint).frame(width: UIScale.pt(5), height: UIScale.pt(5))
                Capsule().fill(DashSkin.inkSoft(dark).opacity(0.6))
                    .frame(width: UIScale.pt(width), height: UIScale.pt(3))
            }
            Capsule().fill(DashSkin.inkFaint(dark).opacity(0.4))
                .frame(width: UIScale.pt(width - 8), height: UIScale.pt(3))
        }
        .padding(.horizontal, UIScale.pt(5))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(23), alignment: .leading)
        .background(DashSkin.paper(dark), in: shape)
        .overlay {
            shape.strokeBorder(emphasis > 0 ? tint.opacity(emphasis) : DashSkin.lineStrong(dark))
        }
    }

    private func quinjetPreview(phase: Double) -> some View {
        let highlighted = sin(phase * 1.4) > 0.1
        return HStack(spacing: UIScale.pt(8)) {
            EdithIconView(.folder)
                .font(.system(size: UIScale.pt(15)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text("edith")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("local project")
                    .font(DashSkin.mono(7))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: UIScale.pt(3)) {
                Text("2 worktrees")
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
                    .foregroundStyle(highlighted ? DashSkin.accent(dark) : DashSkin.ink(dark))
                Text("opened recently")
                    .font(.system(size: UIScale.pt(7.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(7))
            .background(
                highlighted ? DashSkin.accent(dark).opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .strokeBorder(
                        highlighted ? DashSkin.accent(dark).opacity(0.7) : DashSkin.lineStrong(dark)
                    )
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func systemPreview(phase: Double) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            ForEach(Array(["⌘", "⌥", "E", "⏎"].enumerated()), id: \.offset) { index, key in
                let press = CGFloat(max(0, sin(phase * 2.2 - Double(index) * 0.7)))
                Text(key)
                    .font(.system(size: UIScale.pt(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(DashSkin.ink(dark))
                    .frame(width: UIScale.pt(30), height: UIScale.pt(28))
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

    private func keystrokeHighlightPreview(phase: Double) -> some View {
        let active = Int(phase * 2) % 3
        return HStack(spacing: UIScale.pt(6)) {
            ForEach(Array(["⌘", "⇧", "A"].enumerated()), id: \.offset) { index, key in
                Text(key)
                    .font(.system(size: UIScale.pt(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(index == active ? 1 : 0.76))
                    .frame(width: UIScale.pt(29), height: UIScale.pt(27))
                    .background(
                        Color(red: 0.08, green: 0.09, blue: 0.11),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(6))
                            .strokeBorder(.white.opacity(index == active ? 0.5 : 0.24))
                    }
                    .shadow(color: .black.opacity(0.45), radius: 0, y: index == active ? 1 : 3)
                    .offset(y: index == active ? 2 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func maintenancePreview(phase: Double) -> some View {
        let active = Int(phase * 1.7) % 3
        return VStack(spacing: UIScale.pt(5)) {
            ForEach(0..<3) { index in
                HStack(spacing: UIScale.pt(7)) {
                    EdithIconView(index == 1 ? .appTile : .terminal)
                        .font(.system(size: UIScale.pt(8)))
                        .foregroundStyle(
                            index == active ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .frame(width: UIScale.pt(12))
                    RoundedRectangle(cornerRadius: UIScale.pt(2))
                        .fill(
                            index == active
                                ? DashSkin.accent(dark).opacity(0.65)
                                : DashSkin.lineStrong(dark)
                        )
                        .frame(
                            width: UIScale.pt(Double(54 - index * 7)), height: UIScale.pt(5))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(index == 0 ? DashSkin.sage : DashSkin.inkFaint(dark).opacity(0.35))
                        .frame(width: UIScale.pt(5), height: UIScale.pt(5))
                }
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func machinesPreview(phase: Double) -> some View {
        let pulse = CGFloat(max(0, sin(phase * 2.1)))
        let bars = (0..<4).map { index in
            CGFloat(0.32 + (sin(phase * 1.5 + Double(index) * 0.8) + 1) * 0.28)
        }
        return HStack(spacing: UIScale.pt(12)) {
            VStack(spacing: UIScale.pt(3)) {
                EdithIconView(.laptop)
                    .font(.system(size: UIScale.pt(15)))
                Text("MAC")
                    .font(DashSkin.mono(6, weight: .semibold))
            }
            .foregroundStyle(DashSkin.inkSoft(dark))

            HStack(spacing: UIScale.pt(3)) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(DashSkin.accent(dark).opacity(index == Int(phase * 2) % 3 ? 1 : 0.25))
                        .frame(width: UIScale.pt(3), height: UIScale.pt(3))
                }
            }

            VStack(spacing: UIScale.pt(4)) {
                HStack(spacing: UIScale.pt(4)) {
                    Circle()
                        .fill(DashSkin.sage.opacity(0.55 + pulse * 0.45))
                        .frame(width: UIScale.pt(4), height: UIScale.pt(4))
                    Text("HOST")
                        .font(DashSkin.mono(6, weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                HStack(alignment: .bottom, spacing: UIScale.pt(2.5)) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(DashSkin.accent(dark).opacity(0.85))
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
        return VStack(spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(10)) {
                statLabel("CPU", value: "\(percentage)%")
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: UIScale.pt(3)) {
                    ForEach(0..<12) { index in
                        let wave = sin(phase * Double.pi * 2 / 3.2 + Double(index) * 1.13)
                        Capsule()
                            .fill(
                                index > 7
                                    ? DashSkin.accent(dark).opacity(0.72) : DashSkin.accent(dark)
                            )
                            .frame(width: UIScale.pt(4), height: UIScale.pt(7 + (wave + 1) * 7.5))
                    }
                }
                .frame(height: UIScale.pt(23), alignment: .bottom)
            }
            HStack(spacing: UIScale.pt(10)) {
                statLabel("MEM", value: "62%")
                Spacer(minLength: 0)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DashSkin.lineStrong(dark))
                        Capsule().fill(DashSkin.accent(dark).opacity(0.72))
                            .frame(width: proxy.size.width * 0.62)
                    }
                }
                .frame(width: UIScale.pt(81), height: UIScale.pt(7))
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statLabel(_ title: String, value: String) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Text(title)
                .font(DashSkin.mono(7, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(DashSkin.mono(10, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.28), value: value)
        }
    }

    private func micMutePreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.2)
        let slashEntry = smoothed(clamped((progress - 0.25) / 0.14))
        let slashExit = smoothed(clamped((progress - 0.68) / 0.14))
        let slashVisibility = slashEntry * (1 - slashExit)
        let barStrength = 1 - slashEntry + slashExit
        let muted = slashVisibility > 0.5
        return HStack(spacing: UIScale.pt(16)) {
            micMuteArt(phase: phase, entry: slashEntry, exit: slashExit, strength: barStrength)
            Text(muted ? "Muted" : "Live")
                .font(.system(size: UIScale.pt(9), weight: .semibold))
                .foregroundStyle(muted ? DashSkin.onAccent(dark) : DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(9))
                .frame(height: UIScale.pt(20))
                .background(
                    muted ? DashSkin.accent(dark) : DashSkin.paper(dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func micMuteArt(
        phase: Double, entry slashEntry: Double, exit slashExit: Double,
        strength barStrength: Double
    ) -> some View {
        ZStack {
            HStack(spacing: UIScale.pt(13)) {
                EdithIconView(.mic)
                    .font(.system(size: UIScale.pt(24), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                HStack(alignment: .center, spacing: UIScale.pt(4)) {
                    ForEach(0..<3) { index in
                        let wave = (sin(phase * 4.4 + Double(index) * 1.7) + 1) / 2
                        let fullHeight = CGFloat(10 + index * 5) + CGFloat(wave * 7)
                        Capsule()
                            .fill(DashSkin.accent(dark).opacity(0.72 + Double(index) * 0.12))
                            .frame(
                                width: UIScale.pt(4),
                                height: max(3, fullHeight * CGFloat(barStrength)))
                    }
                }
                .frame(height: UIScale.pt(29))
            }
            Capsule()
                .fill(DashSkin.accent(dark))
                .frame(width: UIScale.pt(70), height: UIScale.pt(3))
                .scaleEffect(x: CGFloat(slashEntry), anchor: .leading)
                .rotationEffect(.degrees(-32))
                .offset(y: UIScale.pt(-slashExit * 13))
                .opacity(slashEntry * (1 - slashExit))
        }
    }

    private func lidAwakePreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 3.6)
        let close = smoothed(clamped((progress - 0.12) / 0.3))
        let open = smoothed(clamped((progress - 0.74) / 0.2))
        let shut = close - open
        let pulse = (sin(phase * 3.1) + 1) / 2
        let lidHeight = UIScale.pt(46) * CGFloat(1 - shut * 0.9)
        return HStack(spacing: UIScale.pt(18)) {
            VStack(spacing: 0) {
                HostPreviewTrapezoid(inset: UIScale.pt(10) * CGFloat(shut))
                    .fill(DashSkin.paper2(dark))
                    .overlay {
                        HostPreviewTrapezoid(inset: UIScale.pt(10) * CGFloat(shut))
                            .stroke(DashSkin.lineStrong(dark), lineWidth: UIScale.pt(1))
                    }
                    .frame(width: UIScale.pt(70), height: lidHeight)
                Capsule()
                    .fill(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(84), height: UIScale.pt(5))
            }
            .frame(height: UIScale.pt(51), alignment: .bottom)
            HStack(spacing: UIScale.pt(5)) {
                Circle()
                    .fill(DashSkin.sage.opacity(0.55 + pulse * 0.45))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                Text("Still running")
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func calendarPreview(phase: Double) -> some View {
        let palette = [
            Color(red: 0.82, green: 0.45, blue: 0.38),
            Color(red: 0.42, green: 0.62, blue: 0.48),
            Color(red: 0.43, green: 0.55, blue: 0.76),
        ]
        let meetings = [("9:30", "Standup"), ("11:00", "Design review"), ("14:15", "1:1 with Sam")]
        return VStack(spacing: UIScale.pt(5)) {
            ForEach(Array(meetings.enumerated()), id: \.offset) { index, meeting in
                HStack(spacing: UIScale.pt(7)) {
                    Text(meeting.0)
                        .font(DashSkin.mono(7.5, weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(28), alignment: .trailing)
                    Capsule().fill(palette[index])
                        .frame(width: UIScale.pt(3), height: UIScale.pt(16))
                    Text(meeting.1)
                        .font(.system(size: UIScale.pt(9), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer(minLength: 0)
                    if index == 0 {
                        Text("Join")
                            .font(.system(size: UIScale.pt(8), weight: .semibold))
                            .foregroundStyle(DashSkin.onAccent(dark))
                            .padding(.horizontal, UIScale.pt(8))
                            .frame(height: UIScale.pt(16))
                            .background(
                                DashSkin.accent(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(5)))
                    }
                }
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notchPreview(phase: Double) -> some View {
        let pulse = (sin(phase * 1.8) + 1) / 2
        return VStack(spacing: UIScale.pt(0)) {
            BottomRoundedRectangle(radius: UIScale.pt(12))
                .fill(Color.black)
                .frame(width: UIScale.pt(80 + pulse * 44), height: UIScale.pt(20 + pulse * 13))
            Spacer(minLength: 0)
            HStack(spacing: UIScale.pt(5)) {
                Circle().fill(DashSkin.accent(dark)).frame(
                    width: UIScale.pt(5), height: UIScale.pt(5))
                Capsule().fill(DashSkin.lineStrong(dark)).frame(
                    width: UIScale.pt(38), height: UIScale.pt(4))
            }
        }
        .padding(.top, UIScale.pt(1))
        .padding(.bottom, UIScale.pt(7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clipboardPreview(phase: Double) -> some View {
        VStack(spacing: UIScale.pt(6)) {
            ForEach(0..<3) { index in
                let progress = (sin(phase * 1.8 - Double(index) * 0.8) + 1) / 2
                HStack(spacing: UIScale.pt(8)) {
                    RoundedRectangle(cornerRadius: UIScale.pt(3))
                        .fill(DashSkin.accent(dark).opacity(0.55 + Double(index) * 0.12))
                        .frame(width: UIScale.pt(12), height: UIScale.pt(12))
                    Capsule()
                        .fill(DashSkin.inkFaint(dark).opacity(0.48))
                        .frame(width: UIScale.pt(Double(88 - index * 16)), height: UIScale.pt(5))
                    Spacer(minLength: 0)
                    Text("⌘\(index + 1)")
                        .font(DashSkin.mono(8, weight: .medium))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .opacity(0.5 + progress * 0.5)
            }
        }
        .padding(.horizontal, UIScale.pt(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func musicPreview(animating: Bool) -> some View {
        let accent = DashSkin.accent(dark)
        return HStack(spacing: UIScale.pt(12)) {
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent, DashSkin.accentDeep(dark)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .frame(width: UIScale.pt(60), height: UIScale.pt(60))
                .overlay {
                    EdithIconView(.music)
                        .font(.system(size: UIScale.pt(24), weight: .semibold))
                        .foregroundStyle(DashSkin.onAccent(dark))
                }
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                HStack(alignment: .center, spacing: UIScale.pt(6)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Capsule().fill(DashSkin.inkSoft(dark).opacity(0.65)).frame(
                            width: UIScale.pt(66), height: UIScale.pt(5))
                        Capsule().fill(DashSkin.inkFaint(dark).opacity(0.42)).frame(
                            width: UIScale.pt(44), height: UIScale.pt(4))
                    }
                    Spacer(minLength: 0)
                    if animating {
                        HostPreviewWave(
                            playing: true, color: accent, barCount: 5, maxHeight: UIScale.pt(16))
                    } else {
                        HStack(alignment: .bottom, spacing: UIScale.pt(2)) {
                            ForEach([7.0, 12, 16, 9, 13], id: \.self) { height in
                                Capsule().fill(accent).frame(
                                    width: UIScale.pt(3), height: UIScale.pt(height))
                            }
                        }
                        .frame(height: UIScale.pt(16), alignment: .bottom)
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DashSkin.lineStrong(dark))
                        Capsule().fill(accent).frame(width: proxy.size.width * 0.42)
                    }
                }
                .frame(height: UIScale.pt(4))
                HStack(spacing: UIScale.pt(14)) {
                    ForEach([EdithIcon.rewind, .pause, .fastForward], id: \.self) { icon in
                        EdithIconView(icon)
                            .font(.system(size: UIScale.pt(icon == .pause ? 13 : 9)))
                            .foregroundStyle(DashSkin.ink(dark))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func windowSweatersPreview(phase: Double) -> some View {
        let progress = loopProgress(phase, duration: 6)
        let swatches = HostMarketplaceArtwork.swatches(theme: themeName)
        let position = progress * Double(swatches.count)
        let index = Int(position) % swatches.count
        let next = (index + 1) % swatches.count
        let blend = clamped((position - Double(Int(position))) * 3 - 2)
        return ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(DashSkin.paper2(dark))
                .frame(width: UIScale.pt(70), height: UIScale.pt(36))
                .offset(x: UIScale.pt(-14), y: UIScale.pt(-8))
                .opacity(0.55)
            ZStack {
                Image(nsImage: swatches[index])
                    .resizable()
                    .opacity(1 - blend)
                Image(nsImage: swatches[next])
                    .resizable()
                    .opacity(blend)
            }
            .frame(width: UIScale.pt(84), height: UIScale.pt(50))
            .offset(x: UIScale.pt(12), y: UIScale.pt(8))
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
                .offset(x: UIScale.pt(-15), y: UIScale.pt(-7))
                .opacity(backOpacity)
            RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                .fill(DashSkin.paper(dark))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
                        .strokeBorder(
                            DashSkin.accent(dark).opacity(0.5), lineWidth: UIScale.pt(1.5))
                }
                .frame(width: UIScale.pt(76), height: UIScale.pt(39))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: UIScale.pt(4)) {
                        Circle().fill(DashSkin.accent(dark)).frame(
                            width: UIScale.pt(5), height: UIScale.pt(5))
                        Capsule().fill(DashSkin.inkFaint(dark)).frame(
                            width: UIScale.pt(24), height: UIScale.pt(4))
                    }
                    .padding(UIScale.pt(8))
                }
                .offset(x: UIScale.pt(15), y: UIScale.pt(7))
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
                    .fill(DashSkin.accent(dark).opacity(0.76))
                    .frame(width: UIScale.pt(76), height: UIScale.pt(5))
                Capsule()
                    .fill(DashSkin.inkFaint(dark).opacity(0.52))
                    .frame(width: UIScale.pt(50), height: UIScale.pt(4))
            }
            Capsule()
                .fill(DashSkin.paper(dark).opacity(0.92))
                .frame(width: UIScale.pt(30), height: UIScale.pt(11))
                .blur(radius: UIScale.pt(3.5))
                .offset(x: UIScale.pt(-48 + travel * 96))
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
                .offset(x: UIScale.pt(-49 + travel * 98), y: UIScale.pt(-7))
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

    private func homebrewPreview(phase: Double) -> some View {
        let active = Int(phase * 1.4) % 3
        let labels = ["formula", "cask", "tap"]
        return VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            ForEach(0..<3) { index in
                HStack(spacing: UIScale.pt(7)) {
                    EdithIconView(index == 2 ? .homebrew : .box)
                        .font(.system(size: UIScale.pt(8)))
                        .foregroundStyle(
                            index == active ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .frame(width: UIScale.pt(12))
                    Text(labels[index])
                        .font(DashSkin.mono(7, weight: .medium))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    RoundedRectangle(cornerRadius: UIScale.pt(2))
                        .fill(
                            index == active
                                ? DashSkin.accent(dark).opacity(0.65)
                                : DashSkin.lineStrong(dark)
                        )
                        .frame(width: UIScale.pt(Double(34 - index * 6)), height: UIScale.pt(5))
                    Spacer(minLength: 0)
                    Text(index == active ? "↑" : "✓")
                        .font(DashSkin.mono(7, weight: .semibold))
                        .foregroundStyle(
                            index == active ? DashSkin.accent(dark) : DashSkin.sage)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cleanerPreview(phase: Double) -> some View {
        let reclaimed = CGFloat(0.35 + (sin(phase * 1.6) + 1) * 0.22)
        return VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                Text("RECLAIMABLE")
                    .font(DashSkin.mono(7, weight: .semibold))
                Spacer()
                Text("\(Int(reclaimed * 48)) GB")
                    .font(DashSkin.mono(8, weight: .medium))
                    .foregroundStyle(DashSkin.accent(dark))
            }
            GeometryReader { proxy in
                let shares: [CGFloat] = [0.42, 0.26, 0.19, 0.13]
                let gap = UIScale.pt(3)
                let usable = max(0, proxy.size.width - gap * CGFloat(shares.count - 1))
                HStack(spacing: gap) {
                    ForEach(0..<shares.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(
                                index == 0
                                    ? DashSkin.accent(dark)
                                    : DashSkin.accent(dark).opacity(0.55 - Double(index) * 0.14)
                            )
                            .frame(width: usable * reclaimed * shares[index])
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: UIScale.pt(7))
            .clipped()
            HStack(spacing: UIScale.pt(8)) {
                ForEach(["caches", "logs", "builds"], id: \.self) { label in
                    Text(label)
                        .font(DashSkin.mono(6.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(15))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func downloadsPreview(phase: Double) -> some View {
        let progress = [0.82, 0.46, 0.0]
        let pulse = CGFloat(0.46 + (sin(phase * 2.4) + 1) * 0.18)
        return VStack(spacing: UIScale.pt(5)) {
            ForEach(0..<3) { index in
                HStack(spacing: UIScale.pt(7)) {
                    EdithIconView(index == 2 ? .clock : (index == 0 ? .success : .arrowDown))
                        .font(.system(size: UIScale.pt(8)))
                        .foregroundStyle(index == 0 ? DashSkin.sage : DashSkin.accent(dark))
                        .frame(width: UIScale.pt(12))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DashSkin.lineStrong(dark))
                            Capsule()
                                .fill(index == 0 ? DashSkin.sage : DashSkin.accent(dark))
                                .frame(
                                    width: max(
                                        0,
                                        proxy.size.width
                                            * (index == 1 ? pulse : progress[index])))
                        }
                    }
                    .frame(height: UIScale.pt(5))
                }
            }
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func audioMixerPreview(phase: Double) -> some View {
        let track = 48.0
        let channels: [EdithIcon] = [.music, .video, .message, .globe]
        return HStack(alignment: .bottom, spacing: UIScale.pt(26)) {
            ForEach(Array(channels.enumerated()), id: \.offset) { index, icon in
                let level = 0.3 + (sin(phase * 2.2 + Double(index) * 0.9) + 1) * 0.32
                VStack(spacing: UIScale.pt(6)) {
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(DashSkin.lineStrong(dark))
                            .frame(width: UIScale.pt(6))
                        Capsule()
                            .fill(
                                index == 1
                                    ? DashSkin.accent(dark)
                                    : DashSkin.accent(dark).opacity(0.5)
                            )
                            .frame(width: UIScale.pt(6), height: UIScale.pt(track * level))
                    }
                    .frame(height: UIScale.pt(track))
                    EdithIconView(icon)
                        .font(.system(size: UIScale.pt(9), weight: .medium))
                        .foregroundStyle(
                            index == 1 ? DashSkin.accent(dark) : DashSkin.inkFaint(dark)
                        )
                        .frame(width: UIScale.pt(14), height: UIScale.pt(12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum HostExtensionPreviewMotionPolicy {
    static let restingPhase = 1.1
    static let hoverPhase = 2.2
    static let mutedPhase = 1.6
    static let unmutedPhase = 0.2
    static let lidClosingPhase = 1.0
    static let lidClosedPhase = 2.0

    static func animates(hovering: Bool, reduceMotion: Bool) -> Bool {
        hovering && !reduceMotion
    }

    static func phase(for id: String, hovering: Bool, reduceMotion: Bool) -> Double {
        let active = animates(hovering: hovering, reduceMotion: reduceMotion)
        switch id {
        case "micMute": return active ? unmutedPhase : mutedPhase
        case "lidAwake": return active ? lidClosedPhase : lidClosingPhase
        default: return active ? hoverPhase : restingPhase
        }
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
