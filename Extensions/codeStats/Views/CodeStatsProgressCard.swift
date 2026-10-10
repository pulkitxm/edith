import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsProgressCard: View {
    let progress: CodeStatsRunProgress
    let trigger: CodeStatsTrigger?
    let cancelling: Bool
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageCard(
            title: trigger == .scheduled ? "Scheduled refresh" : "Refreshing"
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                CodeStatsPhaseStepper(current: progress.phase, dark: dark)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LoadingProgress(value: progress.overallFraction)
                        .progressViewStyle(.linear)
                        .tint(DashSkin.accent(dark))
                    HStack {
                        Text(
                            CodeStatsProgressMath.repositories(progress)
                                ?? progress.phase.stepTitle + "...")
                        Spacer()
                        Text(
                            progress.overallFraction, format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    }
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                }
                if !progress.inFlight.isEmpty {
                    CodeStatsInFlight(repositories: progress.inFlight, dark: dark)
                }
                HStack(spacing: UIScale.pt(18)) {
                    counter("Synced", progress.synced, DashSkin.ok)
                    counter("Failed", progress.failed, DashSkin.danger)
                    if progress.skipped > 0 {
                        counter("Skipped", progress.skipped, DashSkin.inkFaint(dark))
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        CodeStatsElapsed(progress: progress, now: context.date, dark: dark)
                    }
                    Button("Cancel", role: .cancel, action: cancel)
                        .disabled(cancelling)
                }
                if let error = progress.recentErrors.last {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.warn)
                        .lineLimit(2)
                }
            }
        }
    }

    private func counter(_ title: String, _ value: Int, _ tint: Color) -> some View {
        HStack(spacing: UIScale.pt(5)) {
            Circle().fill(tint).frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text("\(value) \(title.lowercased())")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .monospacedDigit()
        }
    }
}

private struct CodeStatsPhaseStepper: View {
    let current: CodeStatsPhase
    let dark: Bool

    var body: some View {
        let step = CodeStatsProgressMath.step(current)
        HStack(spacing: UIScale.pt(6)) {
            ForEach(Array(CodeStatsPhase.allCases.enumerated()), id: \.element) { index, phase in
                HStack(spacing: UIScale.pt(6)) {
                    ZStack {
                        Circle()
                            .fill(index <= step ? DashSkin.accent(dark) : DashSkin.grid(dark))
                        if index < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: UIScale.pt(9), weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: UIScale.pt(10), weight: .semibold))
                                .foregroundStyle(index == step ? .white : DashSkin.inkSoft(dark))
                        }
                    }
                    .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                    Text(phase.stepTitle)
                        .font(
                            .system(
                                size: UIScale.pt(12), weight: index == step ? .semibold : .regular)
                        )
                        .foregroundStyle(
                            index <= step ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
                        )
                        .lineLimit(1)
                    if index < CodeStatsPhase.allCases.count - 1 {
                        Rectangle()
                            .fill(index < step ? DashSkin.accent(dark) : DashSkin.line(dark))
                            .frame(height: UIScale.pt(2))
                            .frame(minWidth: UIScale.pt(10))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of 5, \(current.stepTitle)")
    }
}

private struct CodeStatsInFlight: View {
    let repositories: [String]
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            LoadingIndicator()
            Text(repositories.prefix(4).joined(separator: ", "))
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
                .truncationMode(.tail)
            if repositories.count > 4 {
                Text("+\(repositories.count - 4)")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }
}

private struct CodeStatsElapsed: View {
    let progress: CodeStatsRunProgress
    let now: Date
    let dark: Bool

    var body: some View {
        let elapsed = CodeStatsProgressMath.duration(
            CodeStatsProgressMath.elapsed(progress, now: now))
        let remaining = CodeStatsProgressMath.remaining(progress, now: now).map {
            ", about " + CodeStatsProgressMath.duration($0) + " left"
        }
        Text(elapsed + " elapsed" + (remaining ?? ""))
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .monospacedDigit()
    }
}
