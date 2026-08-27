import EdithKit
import SwiftUI

struct DisplayPowerRows: View {
    @AppStorage(AppStorageKeys.DisplayPower.enabled, store: SharedDefaults.store) private
        var enabled =
        false
    @AppStorage(
        AppStorageKeys.DisplayPower.bluetoothOffDuringSleep, store: SharedDefaults.store)
    private var bluetoothOffDuringSleep = false
    @AppStorage(AppStorageKeys.DisplayPower.xdrBoostEnabled, store: SharedDefaults.store) private
        var xdrBoostEnabled = false
    @State private var snapshot: DisplayPowerSnapshot?
    @State private var brightness: [UInt32: Double] = [:]
    @State private var xdrLevel = 0.5
    @State private var message: String?
    @State private var failure: String?

    var body: some View {
        Group {
            Section("Displays") {
                if let snapshot, !snapshot.displays.isEmpty {
                    ForEach(snapshot.displays) { display in
                        displayRow(display)
                    }
                } else {
                    LabeledContent("Status", value: "Discovering displays")
                    Text("The menu bar helper publishes brightness routes after it starts.")
                        .settingsCaption()
                }
                Button("Refresh display status") { reload(after: .milliseconds(150)) }
            }

            Section("Extra brightness") {
                Toggle(
                    "Use XDR headroom",
                    isOn: $xdrBoostEnabled.configured(
                        AppStorageKeys.DisplayPower.xdrBoostEnabled)
                )
                .disabled(snapshot?.xdrSupported != true)
                Slider(value: $xdrLevel, in: 0...1, step: 0.05) {
                    Text("Extra brightness")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
                .disabled(!xdrBoostEnabled || snapshot?.xdrSupported != true)
                HStack {
                    Text(xdrStatus)
                        .settingsCaption()
                    Spacer()
                    Button("Apply XDR level") { applyXDR() }
                        .disabled(!xdrBoostEnabled || snapshot?.xdrSupported != true)
                }
            }

            Section("Sleep") {
                Toggle(
                    "Turn Bluetooth off while sleeping",
                    isOn: $bluetoothOffDuringSleep.configured(
                        AppStorageKeys.DisplayPower.bluetoothOffDuringSleep)
                )
                .disabled(snapshot?.bluetoothSupported == false)
                Text(
                    "Bluetooth returns on wake only when Edith turned it off. Bluetooth that was already off stays off."
                )
                .settingsCaption()
                if SharedDefaults.store.bool(
                    forKey: AppStorageKeys.DisplayPower.bluetoothRestorePending)
                {
                    Label("Bluetooth restoration is pending for wake.", systemImage: "moon.zzz")
                        .settingsCaption()
                }
            }

            if let message {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .task { reload() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged)
        ) { _ in
            reload(after: .milliseconds(150))
        }
    }

    private func displayRow(_ display: DisplayPowerDisplay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(
                    display.name,
                    systemImage: display.builtIn ? "laptopcomputer" : "display")
                Spacer()
                Text(methodLabel(display.method))
                    .settingsCaption()
            }
            Slider(
                value: Binding(
                    get: { brightness[display.id] ?? display.brightness },
                    set: { brightness[display.id] = $0 }),
                in: 0...1, step: 0.01
            ) {
                Text("Brightness")
            } minimumValueLabel: {
                Image(systemName: "sun.min")
            } maximumValueLabel: {
                Image(systemName: "sun.max.fill")
            }
            .disabled(display.method == .unavailable)
            HStack {
                Text("\(Int(((brightness[display.id] ?? display.brightness) * 100).rounded()))%")
                    .monospacedDigit()
                    .settingsCaption()
                Spacer()
                Button("Apply") { applyBrightness(display.id) }
                    .disabled(display.method == .unavailable)
            }
        }
    }

    private var xdrStatus: String {
        guard snapshot?.xdrSupported == true else {
            return "Available only on a built-in Liquid Retina XDR panel."
        }
        if snapshot?.xdrBoosting == true { return "Extra brightness is active." }
        return "macOS controls available HDR headroom for power and temperature safety."
    }

    private func methodLabel(_ method: DisplayBrightnessMethod) -> String {
        switch method {
        case .system: "System brightness"
        case .ddc: "Monitor controls"
        case .software: "Software dimming"
        case .unavailable: "Unavailable"
        }
    }

    private func applyBrightness(_ displayID: UInt32) {
        let percent = Int(((brightness[displayID] ?? 1) * 100).rounded())
        do {
            _ = try DisplayPowerOperationExecution.setBrightness(
                percent: percent, displayID: displayID)
            message = "Applied \(percent)% brightness."
            failure = nil
            reload(after: .milliseconds(200))
        } catch {
            failure = error.localizedDescription
            message = nil
        }
    }

    private func applyXDR() {
        do {
            try DisplayPowerOperationExecution.setXDR(
                enabled: true, percent: Int((xdrLevel * 100).rounded()))
            message = "Applied the XDR extra brightness level."
            failure = nil
            reload(after: .milliseconds(200))
        } catch {
            failure = error.localizedDescription
            message = nil
        }
    }

    private func reload(after delay: Duration = .zero) {
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let value = try? DisplayPowerOperationExecution.snapshot() else { return }
            snapshot = value
            brightness = Dictionary(
                uniqueKeysWithValues: value.displays.map { ($0.id, $0.brightness) })
            xdrLevel =
                Double(
                    SharedDefaults.store.object(forKey: AppStorageKeys.DisplayPower.xdrBoostLevel)
                        as? Int ?? 50) / 100
        }
    }
}
