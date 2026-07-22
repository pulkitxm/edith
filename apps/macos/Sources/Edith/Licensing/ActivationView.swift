import AppKit
import EdithKit
import SwiftUI

struct ActivationView: View {
    let licenseState: LicenseState
    let client: LicenseClient
    let onActivated: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var keyFieldFocused: Bool
    @State private var key = "EDITH-"
    @State private var deviceName = Host.current().localizedName ?? ""
    @State private var activating = false
    @State private var errorMessage: String?
    @State private var seatLimitHit = false

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            Spacer(minLength: 34)
            appIcon
                .frame(width: UIScale.pt(72), height: UIScale.pt(72))
                .shadow(color: .black.opacity(dark ? 0.3 : 0.14), radius: UIScale.pt(14), y: 7)
            Text("Activate Edith")
                .font(DashSkin.serif(30, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, UIScale.pt(18))
            Text("Enter your license key")
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .padding(.top, UIScale.pt(5))
            EdithTextField(
                placeholder: "EDITH-XXXX-XXXX-XXXX-XXXX", text: $key,
                font: DashSkin.mono(15, weight: .medium), alignment: .center,
                invalid: errorMessage != nil, focus: $keyFieldFocused, onSubmit: activate
            )
            .disabled(activating)
            .padding(.top, UIScale.pt(20))
            .onChange(of: key) { _, value in
                let formatted = LicenseKeyFormatting.format(value)
                if formatted != value { key = formatted }
                errorMessage = nil
            }
            EdithTextField(
                placeholder: "Device name (optional)", text: $deviceName, alignment: .center
            )
            .disabled(activating)
            .padding(.top, UIScale.pt(10))
            Button(action: activate) {
                Group {
                    if activating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Text("Activate")
                    }
                }
                .font(.system(size: UIScale.pt(14), weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(38))
                .background(brandAccent, in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            }
            .buttonStyle(.plain)
            .disabled(activating || !LicenseKeyFormatting.isComplete(key))
            .opacity(LicenseKeyFormatting.isComplete(key) ? 1 : 0.55)
            .keyboardShortcut(.defaultAction)
            .pointerCursor()
            .padding(.top, UIScale.pt(12))
            Text(errorMessage ?? " ")
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.danger)
                .frame(height: UIScale.pt(17))
                .padding(.top, UIScale.pt(8))
            Spacer(minLength: 18)
            if seatLimitHit {
                Divider()
                    .overlay(DashSkin.line(dark))
                Text("Keys are limited to a number of Macs")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(height: UIScale.pt(42))
            }
        }
        .padding(.horizontal, UIScale.pt(52))
        .frame(width: UIScale.pt(440), height: UIScale.pt(440))
        .background(DashSkin.paper(dark))
        .task { keyFieldFocused = true }
    }

    private var appIcon: some View {
        Group {
            if let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
                let icon = NSImage(contentsOf: url)
            {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(brandAccent)
            }
        }
    }

    private func activate() {
        guard !activating, LicenseKeyFormatting.isComplete(key) else { return }
        activating = true
        errorMessage = nil
        let formattedKey = LicenseKeyFormatting.format(key)
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await LicenseSession(client: client).activate(
                    licenseKey: formattedKey,
                    deviceName: trimmedName.isEmpty ? nil : trimmedName)
                try? licenseState.activate(key: formattedKey, label: "Licensed")
                onActivated()
            } catch {
                handleActivationError(error)
            }
        }
    }

    private func handleActivationError(_ error: Error) {
        switch error {
        case LicenseClientError.machineLimitReached(let machinesUsed, let maxMachines):
            errorMessage = "This key is already active on \(machinesUsed) of \(maxMachines) Macs."
            seatLimitHit = true
        case LicenseClientError.seatLimitReached:
            errorMessage = "This key has reached its Mac limit."
            seatLimitHit = true
        case LicenseClientError.invalidKey:
            errorMessage = "That license key is invalid or inactive."
        default:
            errorMessage = "Could not activate. Check your connection and try again."
        }
        activating = false
    }
}
