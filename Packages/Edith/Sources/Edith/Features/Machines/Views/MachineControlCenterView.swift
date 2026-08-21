import EdithKit
import SwiftUI

private enum MachineControlConfirmation {
    case disableWiFi
    case enableAirplaneMode

    var title: String {
        switch self {
        case .disableWiFi: "Turn off Wi-Fi?"
        case .enableAirplaneMode: "Turn on airplane mode?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .disableWiFi: "Turn Off Wi-Fi"
        case .enableAirplaneMode: "Turn On Airplane Mode"
        }
    }
}

struct MachineControlCenterButton: View {
    let session: MachineSession
    let dark: Bool

    @State private var presented = false
    @State private var hovering = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Label("Control Center", systemImage: "switch.2")
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(
                    hovering ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                )
                .padding(.horizontal, UIScale.pt(9))
                .frame(height: UIScale.pt(24))
                .background(
                    hovering ? Color.primary.opacity(0.06) : DashSkin.paper2(dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(7))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(7))
                        .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(0.5))
                }
                .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(7)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help("Control this machine's hardware and wireless settings")
        .popover(isPresented: $presented, arrowEdge: .top) {
            MachineControlCenterView(session: session)
        }
    }
}

struct MachineControlCenterView: View {
    let session: MachineSession
    let loadsOnAppear: Bool

    @State private var snapshot: MachineControlSnapshot?
    @State private var brightness = 0
    @State private var volume = 0
    @State private var keyboardBacklight = 0
    @State private var muted = false
    @State private var wifiEnabled = false
    @State private var bluetoothEnabled = false
    @State private var airplaneMode = false
    @State private var doNotDisturb = false
    @State private var isRefreshing = false
    @State private var hasLoaded = false
    @State private var requiresConnection = false
    @State private var isApplyingControl = false
    @State private var isApplyingProfile = false
    @State private var resultMessage: String?
    @State private var resultFailed = false
    @State private var selectedProfile = ""
    @State private var duration = MachineProfileDuration.untilChanged
    @State private var confirmation: MachineControlConfirmation?
    @State private var hoveredRow: String?

    @Environment(\.colorScheme) private var scheme

    init(session: MachineSession, loadsOnAppear: Bool = true) {
        self.session = session
        self.loadsOnAppear = loadsOnAppear
    }

    private var dark: Bool { scheme == .dark }
    private var profile: MachinePlatformProfile? { session.slow?.platformProfile }
    private var fans: [MachineFan] { session.slow?.fans ?? [] }
    private var hasControls: Bool { snapshot.map { !$0.isEmpty } ?? false }
    private var hasCooling: Bool { !fans.isEmpty || profile != nil }
    private var isBusy: Bool {
        isRefreshing || isApplyingControl || isApplyingProfile || session.isApplyingPlatformProfile
    }
    private var controlsDisabled: Bool { isBusy || !session.state.isConnected }
    private var busyLabel: String { isRefreshing ? "Refreshing" : "Updating" }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            header
            Divider().padding(.top, UIScale.pt(10))
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                    if (loadsOnAppear && !hasLoaded && snapshot == nil)
                        || (isRefreshing && snapshot == nil)
                    {
                        loadingState
                    } else if requiresConnection || (!hasControls && !hasCooling) {
                        unavailableState
                    } else {
                        availableControls
                        if let resultMessage {
                            Divider().padding(.leading, UIScale.pt(8))
                            resultRow(resultMessage)
                        }
                    }
                }
            }
            .frame(maxHeight: UIScale.pt(560))
        }
        .padding(UIScale.pt(14))
        .frame(width: UIScale.pt(330))
        .task {
            guard loadsOnAppear else { return }
            await refresh(reportFailure: true, clearsMessage: false)
        }
        .onAppear { synchronizeProfileSelection() }
        .onChange(of: profile) { _, _ in synchronizeProfileSelection() }
        .onChange(of: session.state.isConnected) { _, connected in
            guard connected, requiresConnection else { return }
            Task { await refresh(reportFailure: true, clearsMessage: true) }
        }
        .confirmationDialog(
            confirmation?.title ?? "Confirm network change",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmation?.buttonTitle ?? "Continue", role: .destructive) {
                applyConfirmedNetworkChange()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("This can immediately disconnect SSH. Reconnect through another network path.")
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "switch.2")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.accent(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text("Control Center")
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(session.machine.name)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isBusy {
                HStack(spacing: UIScale.pt(4)) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                    Text(busyLabel)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            Button {
                Task { await refresh(reportFailure: true, clearsMessage: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.35 : 1)
            .pointerCursor()
            .help("Refresh available controls")
        }
    }

    private var loadingState: some View {
        HStack(spacing: UIScale.pt(9)) {
            ProgressView().controlSize(.small)
            Text("Checking available controls…")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(18))
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Label(
                requiresConnection
                    ? "Connect to discover controls"
                    : resultFailed ? "Controls unavailable" : "No controls available",
                systemImage: requiresConnection
                    ? "bolt.horizontal.circle"
                    : resultFailed ? "exclamationmark.triangle" : "switch.2"
            )
            .font(.system(size: UIScale.pt(12.5), weight: .medium))
            .foregroundStyle(resultFailed ? DashSkin.danger : DashSkin.ink(dark))
            Text(
                resultMessage
                    ?? (requiresConnection
                        ? "Reconnect this machine to check its available settings."
                        : "This machine did not report any supported controls.")
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            if requiresConnection {
                Button(session.state.isBusy ? "Connecting…" : "Connect") {
                    session.retry()
                }
                .controlSize(.small)
                .disabled(session.state.isBusy)
                .pointerCursor()
                .padding(.top, UIScale.pt(3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(16))
    }

    @ViewBuilder
    private var availableControls: some View {
        if snapshot?.brightness != nil {
            sliderRow(
                "Brightness", symbol: "sun.max", value: $brightness,
                onCommit: { perform(.setBrightness(brightness), success: "Brightness updated") })
        }
        if snapshot?.volume != nil {
            if hasControl(before: 1) { controlDivider }
            sliderRow(
                "Volume", symbol: "speaker.wave.2", value: $volume,
                onCommit: { perform(.setVolume(volume), success: "Volume updated") })
        }
        if snapshot?.muted != nil {
            if hasControl(before: 2) { controlDivider }
            toggleRow("Mute", symbol: muted ? "speaker.slash.fill" : "speaker.slash", value: muted)
            {
                muted = $0
                perform(.setMuted($0), success: $0 ? "Audio muted" : "Audio unmuted")
            }
        }
        if snapshot?.wifiEnabled != nil {
            if hasControl(before: 3) { controlDivider }
            toggleRow("Wi-Fi", symbol: "wifi", value: wifiEnabled) { next in
                if next {
                    wifiEnabled = true
                    perform(.setWiFiEnabled(true), success: "Wi-Fi turned on")
                } else {
                    confirmation = .disableWiFi
                }
            }
        }
        if snapshot?.bluetoothEnabled != nil {
            if hasControl(before: 4) { controlDivider }
            toggleRow("Bluetooth", symbol: "wave.3.right", value: bluetoothEnabled) {
                bluetoothEnabled = $0
                perform(
                    .setBluetoothEnabled($0),
                    success: $0 ? "Bluetooth turned on" : "Bluetooth turned off")
            }
        }
        if snapshot?.airplaneMode != nil {
            if hasControl(before: 5) { controlDivider }
            toggleRow("Airplane mode", symbol: "airplane", value: airplaneMode) { next in
                if next {
                    confirmation = .enableAirplaneMode
                } else {
                    airplaneMode = false
                    perform(.setAirplaneMode(false), success: "Airplane mode turned off")
                }
            }
        }
        if snapshot?.doNotDisturb != nil {
            if hasControl(before: 6) { controlDivider }
            toggleRow(
                "Do Not Disturb", symbol: "moon.fill", value: doNotDisturb
            ) {
                doNotDisturb = $0
                perform(
                    .setDoNotDisturb($0),
                    success: $0 ? "Do Not Disturb turned on" : "Do Not Disturb turned off")
            }
        }
        if snapshot?.keyboardBacklight != nil {
            if hasControl(before: 7) { controlDivider }
            sliderRow(
                "Keyboard lighting", symbol: "keyboard", value: $keyboardBacklight,
                onCommit: {
                    perform(
                        .setKeyboardBacklight(keyboardBacklight),
                        success: "Keyboard lighting updated")
                })
        }
        if hasControls, hasCooling {
            Divider().padding(.vertical, UIScale.pt(7))
        }
        if hasCooling {
            coolingControls
        }
    }

    private var controlDivider: some View {
        Divider().padding(.leading, UIScale.pt(36))
    }

    private func sliderRow(
        _ title: String, symbol: String, value: Binding<Int>, onCommit: @escaping () -> Void
    ) -> some View {
        let doubleValue = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(18))
                Text(title)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer(minLength: 0)
                Text("\(value.wrappedValue)%")
                    .font(DashSkin.mono(10.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .monospacedDigit()
            }
            Slider(
                value: doubleValue, in: 0...100, step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    onCommit()
                }
            )
            .controlSize(.small)
            .tint(DashSkin.accent(dark))
            .disabled(controlsDisabled)
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(9))
        .background(rowBackground(title))
        .onHover { updateHover(title, hovering: $0) }
    }

    private func toggleRow(
        _ title: String, symbol: String, value: Bool, onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: UIScale.pt(9)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(18))
            Text(title)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: .constant(value))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(8))
        .background(rowBackground(title))
        .contentShape(Rectangle())
        .opacity(controlsDisabled ? 0.55 : 1)
        .onTapGesture {
            guard !controlsDisabled else { return }
            onChange(!value)
        }
        .onHover { updateHover(title, hovering: $0) }
        .pointerCursor()
    }

    private var coolingControls: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            Text("COOLING")
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .tracking(UIScale.pt(0.7))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .padding(.horizontal, UIScale.pt(8))
                .padding(.bottom, UIScale.pt(5))
            ForEach(Array(fans.enumerated()), id: \.element.id) { index, fan in
                if index > 0 { controlDivider }
                HStack(spacing: UIScale.pt(9)) {
                    Image(systemName: "fan")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(18))
                    Text(fan.label)
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer(minLength: 0)
                    Text("\(fan.rpm.formatted()) rpm")
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(8))
            }
            if !fans.isEmpty, profile != nil {
                controlDivider
            }
            if let profile {
                profileControls(profile)
            }
        }
    }

    private func profileControls(_ profile: MachinePlatformProfile) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(18))
                Text("Thermal profile")
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer(minLength: 0)
                Picker("Profile", selection: $selectedProfile) {
                    ForEach(profile.choices, id: \.self) { choice in
                        Text(profileLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: UIScale.pt(132))
                .disabled(controlsDisabled)
                .pointerCursor()
            }
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: "timer")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(18))
                Text("Duration")
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer(minLength: 0)
                Picker("Duration", selection: $duration) {
                    ForEach(MachineProfileDuration.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: UIScale.pt(132))
                .disabled(controlsDisabled)
                .pointerCursor()
            }
            HStack(spacing: UIScale.pt(8)) {
                Text(profileStatus(profile))
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Apply") { applyProfile() }
                    .controlSize(.small)
                    .disabled(selectedProfile.isEmpty || controlsDisabled)
                    .pointerCursor()
            }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(9))
    }

    private func resultRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(7)) {
            Image(systemName: resultFailed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
            Text(message)
                .font(.system(size: UIScale.pt(10.5)))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(resultFailed ? DashSkin.danger : DashSkin.sage)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.top, UIScale.pt(9))
    }

    private func rowBackground(_ title: String) -> some View {
        RoundedRectangle(cornerRadius: UIScale.pt(7))
            .fill(hoveredRow == title ? Color.primary.opacity(0.06) : Color.clear)
    }

    private func updateHover(_ title: String, hovering: Bool) {
        if hovering {
            hoveredRow = title
        } else if hoveredRow == title {
            hoveredRow = nil
        }
    }

    private func refresh(reportFailure: Bool, clearsMessage: Bool) async {
        guard !isRefreshing else { return }
        if clearsMessage { resultMessage = nil }
        guard session.isLocal || session.state.isConnected else {
            requiresConnection = true
            if reportFailure { resultFailed = false }
            hasLoaded = true
            return
        }
        requiresConnection = false
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoaded = true
        }
        switch await session.runCommand(MachineControlCenterCommands.statusCommand, timeout: 20) {
        case let .success(output):
            if reportFailure { resultFailed = false }
            apply(MachineControlCenterCommands.parseStatus(output))
        case let .failure(error):
            guard reportFailure else { return }
            resultFailed = true
            resultMessage = explain(error)
        }
    }

    private func apply(_ next: MachineControlSnapshot) {
        snapshot = next
        if let value = next.brightness { brightness = value }
        if let value = next.volume { volume = value }
        if let value = next.keyboardBacklight { keyboardBacklight = value }
        if let value = next.muted { muted = value }
        if let value = next.wifiEnabled { wifiEnabled = value }
        if let value = next.bluetoothEnabled { bluetoothEnabled = value }
        if let value = next.airplaneMode { airplaneMode = value }
        if let value = next.doNotDisturb { doNotDisturb = value }
    }

    private func perform(_ action: MachineControlAction, success: String) {
        guard !isBusy else { return }
        resultMessage = nil
        isApplyingControl = true
        Task {
            let stdin = SudoPassword.stdin(machineID: session.machine.id)
            let command = MachineControlCenterCommands.command(
                for: action, withSudoPassword: stdin != nil)
            switch await session.runCommand(command, stdin: stdin, timeout: 30) {
            case .success:
                resultFailed = false
                resultMessage = success
                if !canDisconnect(action) || session.state.isConnected {
                    await refresh(reportFailure: false, clearsMessage: false)
                }
            case let .failure(error):
                if canDisconnect(action), PowerOutcome.hostWentAway(error) {
                    resultFailed = false
                    resultMessage = success
                } else {
                    resultFailed = true
                    resultMessage = explain(error)
                    if let snapshot { apply(snapshot) }
                    await refresh(reportFailure: false, clearsMessage: false)
                }
            }
            isApplyingControl = false
        }
    }

    private func applyConfirmedNetworkChange() {
        let confirmed = confirmation
        confirmation = nil
        switch confirmed {
        case .disableWiFi:
            wifiEnabled = false
            perform(.setWiFiEnabled(false), success: "Wi-Fi turned off")
        case .enableAirplaneMode:
            airplaneMode = true
            perform(.setAirplaneMode(true), success: "Airplane mode turned on")
        case nil:
            break
        }
    }

    private func synchronizeProfileSelection() {
        guard let profile else { return }
        if !profile.choices.contains(selectedProfile) {
            selectedProfile = profile.current
        }
    }

    private func applyProfile() {
        guard !selectedProfile.isEmpty, !isBusy else { return }
        resultMessage = nil
        isApplyingProfile = true
        Task {
            switch await session.setPlatformProfile(selectedProfile, duration: duration) {
            case .success:
                resultFailed = false
                resultMessage =
                    duration == .untilChanged
                    ? "Switched to \(profileLabel(selectedProfile))"
                    : "Switched to \(profileLabel(selectedProfile)) for \(duration.label.lowercased())"
            case let .failure(error):
                resultFailed = true
                resultMessage = explain(error)
            }
            isApplyingProfile = false
        }
    }

    private func profileStatus(_ profile: MachinePlatformProfile) -> String {
        guard let revertsAt = session.platformProfileRevertsAt, revertsAt > Date() else {
            return "Currently \(profileLabel(profile.current))"
        }
        return
            "Currently \(profileLabel(profile.current)), reverts \(revertsAt.formatted(date: .omitted, time: .shortened))"
    }

    private func hasControl(before index: Int) -> Bool {
        let available = [
            snapshot?.brightness != nil,
            snapshot?.volume != nil,
            snapshot?.muted != nil,
            snapshot?.wifiEnabled != nil,
            snapshot?.bluetoothEnabled != nil,
            snapshot?.airplaneMode != nil,
            snapshot?.doNotDisturb != nil,
            snapshot?.keyboardBacklight != nil,
        ]
        return available.prefix(index).contains(true)
    }

    private func canDisconnect(_ action: MachineControlAction) -> Bool {
        action == .setWiFiEnabled(false) || action == .setAirplaneMode(true)
    }

    private func profileLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func explain(_ error: Error) -> String {
        PowerOutcome.explain(error)
    }
}
