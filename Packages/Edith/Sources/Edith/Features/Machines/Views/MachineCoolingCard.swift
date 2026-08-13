import EdithKit
import SwiftUI

struct MachineCoolingCard: View {
    let session: MachineSession
    let dark: Bool

    @State private var selectedProfile = ""
    @State private var duration = MachineProfileDuration.untilChanged
    @State private var message: String?
    @State private var failed = false

    private var profile: MachinePlatformProfile? { session.slow?.platformProfile }
    private var fans: [MachineFan] { session.slow?.fans ?? [] }

    var body: some View {
        SkinCard(
            title: "Cooling", note: "Live fan speeds and the machine's thermal profile", dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if !fans.isEmpty {
                    fanRows
                }
                if !fans.isEmpty, profile != nil {
                    Divider().opacity(0.45)
                }
                if let profile {
                    profileControls(profile)
                }
                if let message {
                    Text(message)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(failed ? DashSkin.danger : DashSkin.sage)
                }
            }
        }
        .onAppear { synchronizeSelection() }
        .onChange(of: profile) { _, _ in synchronizeSelection() }
    }

    private var fanRows: some View {
        VStack(spacing: UIScale.pt(8)) {
            ForEach(fans) { fan in
                HStack {
                    Label(fan.label, systemImage: "fan")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer()
                    Text("\(fan.rpm.formatted()) rpm")
                        .font(DashSkin.mono(11))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private func profileControls(_ profile: MachinePlatformProfile) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            HStack(spacing: UIScale.pt(8)) {
                Text("Thermal profile")
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer(minLength: 0)
                Picker("Profile", selection: $selectedProfile) {
                    ForEach(profile.choices, id: \.self) { choice in
                        Text(profileLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: UIScale.pt(145))
                Picker("Duration", selection: $duration) {
                    ForEach(MachineProfileDuration.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: UIScale.pt(135))
                Button("Apply") { apply() }
                    .disabled(
                        selectedProfile.isEmpty || session.isApplyingPlatformProfile
                            || !session.state.isConnected
                    )
                    .pointerCursor()
            }
            HStack(spacing: UIScale.pt(6)) {
                Circle()
                    .fill(DashSkin.sage)
                    .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                Text(profileStatus(profile))
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                if session.isApplyingPlatformProfile {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                }
            }
        }
    }

    private func profileStatus(_ profile: MachinePlatformProfile) -> String {
        guard let revertsAt = session.platformProfileRevertsAt, revertsAt > Date() else {
            return "Currently \(profileLabel(profile.current))"
        }
        return
            "Currently \(profileLabel(profile.current)), reverts \(revertsAt.formatted(date: .omitted, time: .shortened))"
    }

    private func profileLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func synchronizeSelection() {
        guard let profile else { return }
        if !profile.choices.contains(selectedProfile) {
            selectedProfile = profile.current
        }
    }

    private func apply() {
        message = nil
        failed = false
        Task {
            switch await session.setPlatformProfile(selectedProfile, duration: duration) {
            case .success:
                message =
                    duration == .untilChanged
                    ? "Switched to \(profileLabel(selectedProfile))."
                    : "Switched to \(profileLabel(selectedProfile)) for \(duration.label.lowercased())."
            case let .failure(error):
                failed = true
                let detail = error.localizedDescription
                message = [detail, SudoPassword.hint(forRefusal: detail)]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }
    }
}
