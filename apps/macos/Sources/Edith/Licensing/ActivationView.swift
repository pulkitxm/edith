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
        VStack(spacing: 0) {
            Spacer(minLength: 34)
            appIcon
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(dark ? 0.3 : 0.14), radius: 14, y: 7)
            Text("Activate Edith")
                .font(DashSkin.serif(30, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, 18)
            Text("Enter your license key")
                .font(.system(size: 14))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .padding(.top, 5)
            TextField("EDITH-XXXX-XXXX-XXXX-XXXX", text: $key)
                .textFieldStyle(.plain)
                .font(DashSkin.mono(15, weight: .medium))
                .multilineTextAlignment(.center)
                .focused($keyFieldFocused)
                .disabled(activating)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            errorMessage == nil ? DashSkin.lineStrong(dark) : DashSkin.danger,
                            lineWidth: 1
                        )
                }
                .padding(.top, 20)
                .onChange(of: key) { _, value in
                    let formatted = LicenseKeyFormatting.format(value)
                    if formatted != value { key = formatted }
                    errorMessage = nil
                }
                .onSubmit(activate)
            TextField("Device name (optional)", text: $deviceName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .disabled(activating)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DashSkin.line(dark), lineWidth: 1)
                }
                .padding(.top, 10)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(brandAccent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(activating || !LicenseKeyFormatting.isComplete(key))
            .opacity(LicenseKeyFormatting.isComplete(key) ? 1 : 0.55)
            .keyboardShortcut(.defaultAction)
            .pointerCursor()
            .padding(.top, 12)
            Text(errorMessage ?? " ")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DashSkin.danger)
                .frame(height: 17)
                .padding(.top, 8)
            Spacer(minLength: 18)
            if seatLimitHit {
                Divider()
                    .overlay(DashSkin.line(dark))
                Text("Keys are limited to a number of Macs")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(height: 42)
            }
        }
        .padding(.horizontal, 52)
        .frame(width: 440, height: 440)
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
                try await LicenseV2Session(client: client).activate(
                    licenseKey: formattedKey,
                    deviceName: trimmedName.isEmpty ? nil : trimmedName)
                onActivated()
            } catch LicenseClientError.server(statusCode: 404) {
                await activateLegacy(key: formattedKey)
            } catch {
                handleActivationError(error)
            }
        }
    }

    private func activateLegacy(key formattedKey: String) async {
        guard let machine = hardwareUUID() else {
            errorMessage = "This Mac could not be identified."
            activating = false
            return
        }
        do {
            let response = try await client.activate(key: formattedKey, hardwareUuid: machine)
            guard response.ok else {
                errorMessage = "That license key is invalid or inactive."
                activating = false
                return
            }
            try licenseState.activate(
                key: formattedKey, label: response.label, name: response.name,
                receipt: response.receipt)
            onActivated()
        } catch {
            handleActivationError(error)
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
