import EdithKit
import Observation
import SwiftUI

private enum MachineControlConnectionPhase: Hashable {
    case available
    case connecting
    case unavailable
}

@MainActor
@Observable
final class MachineControlCenterModel {
    let session: MachineSession

    var snapshot: MachineControlSnapshot?
    var brightness = 0
    var volume = 0
    var keyboardBacklight = 0
    var muted = false
    var wifiEnabled = false
    var bluetoothEnabled = false
    var airplaneMode = false
    var doNotDisturb = false
    var isRefreshing = false
    var hasLoaded = false
    var requiresConnection = false
    var isApplyingControl = false
    var isApplyingProfile = false
    var resultMessage: String?
    var resultFailed = false
    var selectedProfile = ""
    var duration = MachineProfileDuration.untilChanged

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var lastRefreshStartedAt: Date?

    init(session: MachineSession) {
        self.session = session
    }

    var isBusy: Bool {
        isRefreshing || isApplyingControl || isApplyingProfile
            || session.isApplyingPlatformProfile
    }

    fileprivate func prepare(for phase: MachineControlConnectionPhase) async {
        refreshGeneration &+= 1
        refreshPending = false
        isRefreshing = false
        switch phase {
        case .available:
            await refresh(reportFailure: true, clearsMessage: hasLoaded)
        case .connecting:
            snapshot = nil
            hasLoaded = false
            requiresConnection = false
            resultMessage = nil
            resultFailed = false
        case .unavailable:
            snapshot = nil
            hasLoaded = true
            requiresConnection = true
            resultMessage = nil
            resultFailed = false
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 15) {
        guard session.isLocal || session.state.isConnected else { return }
        guard hasLoaded, !requiresConnection, !isBusy else { return }
        if let lastRefreshStartedAt,
            Date().timeIntervalSince(lastRefreshStartedAt) < maxAge
        {
            return
        }
        let clearsFailure = resultFailed
        Task {
            await refresh(reportFailure: clearsFailure, clearsMessage: clearsFailure)
        }
    }

    func refresh(reportFailure: Bool, clearsMessage: Bool) async {
        let generation = refreshGeneration
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        if clearsMessage { resultMessage = nil }
        guard session.isLocal || session.state.isConnected else {
            snapshot = nil
            requiresConnection = true
            if reportFailure { resultFailed = false }
            hasLoaded = true
            return
        }
        requiresConnection = false
        lastRefreshStartedAt = Date()
        isRefreshing = true
        defer {
            if generation == refreshGeneration, !Task.isCancelled {
                isRefreshing = false
                hasLoaded = true
                if refreshPending {
                    refreshPending = false
                    Task { await refresh(reportFailure: true, clearsMessage: true) }
                }
            }
        }
        let result = await session.runCommand(
            MachineControlCenterCommands.statusCommand, timeout: 20)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        switch result {
        case let .success(output):
            guard session.isLocal || session.state.isConnected else {
                snapshot = nil
                requiresConnection = true
                return
            }
            requiresConnection = false
            if reportFailure { resultFailed = false }
            apply(MachineControlCenterCommands.parseStatus(output))
        case let .failure(error):
            if !session.isLocal && !session.state.isConnected {
                snapshot = nil
                requiresConnection = true
                resultFailed = false
                resultMessage = nil
                return
            }
            guard reportFailure else { return }
            resultFailed = true
            resultMessage = PowerOutcome.explain(error)
        }
    }

    func perform(_ action: MachineControlAction, success: String) {
        guard !isBusy else { return }
        resultMessage = nil
        isApplyingControl = true
        Task {
            let shouldAttachSudoPassword =
                !session.isLocal
                && MachineControlCenterCommands.shouldAttachSudoPassword(
                    for: action, platform: snapshot?.platform)
            let stdin =
                shouldAttachSudoPassword
                ? SudoPassword.stdin(machineID: session.machine.id) : nil
            let command = MachineControlCenterCommands.command(
                for: action, withSudoPassword: stdin != nil,
                usingLocalAuthorization: session.isLocal)
            switch await session.runCommand(command, stdin: stdin, timeout: 30) {
            case .success:
                resultFailed = false
                resultMessage = success
                if !canDisconnect(action) || session.state.isConnected {
                    await refresh(reportFailure: false, clearsMessage: false)
                }
            case let .failure(error):
                if canDisconnect(action), PowerOutcome.hostWentAway(error),
                    MachineControlCenterCommands.disruptiveOperationStarted(error)
                {
                    resultFailed = false
                    resultMessage = success
                } else {
                    resultFailed = true
                    resultMessage = PowerOutcome.explain(error)
                    if let snapshot { apply(snapshot) }
                    await refresh(reportFailure: false, clearsMessage: false)
                }
            }
            isApplyingControl = false
        }
    }

    func synchronizeProfileSelection() {
        guard let profile = session.slow?.platformProfile else { return }
        if !profile.choices.contains(selectedProfile) {
            selectedProfile = profile.current
        }
    }

    func applyProfile() {
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
                resultMessage = PowerOutcome.explain(error)
            }
            isApplyingProfile = false
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

    private func canDisconnect(_ action: MachineControlAction) -> Bool {
        action == .setWiFiEnabled(false) || action == .setAirplaneMode(true)
    }

    private func profileLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

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

    @State private var model: MachineControlCenterModel
    @State private var presented = false
    @State private var hovering = false

    init(session: MachineSession, dark: Bool) {
        self.session = session
        self.dark = dark
        _model = State(initialValue: MachineControlCenterModel(session: session))
    }

    private var connectionPhase: MachineControlConnectionPhase {
        if session.isLocal || session.state.isConnected { return .available }
        if session.state.isBusy { return .connecting }
        return .unavailable
    }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            batteryStatus
            controlButton
        }
        .task(id: connectionPhase) {
            await model.prepare(for: connectionPhase)
        }
    }

    private var controlButton: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "switch.2")
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(
                    hovering ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                )
                .frame(width: UIScale.pt(24), height: UIScale.pt(24))
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
        .accessibilityLabel("Machine controls")
        .onHover {
            hovering = $0
            if $0 { model.refreshIfStale() }
        }
        .pointerCursor()
        .help("Control this machine's hardware and wireless settings")
        .popover(isPresented: $presented, arrowEdge: .top) {
            MachineControlCenterView(model: model)
        }
    }

    @ViewBuilder
    private var batteryStatus: some View {
        if !model.hasLoaded, connectionPhase != .unavailable {
            SkeletonBlock(width: 50, height: 24, corner: 7)
                .accessibilityHidden(true)
        } else if let level = model.snapshot?.batteryLevel {
            HStack(spacing: UIScale.pt(4)) {
                Text("\(level)%")
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .monospacedDigit()
                Image(systemName: batterySymbol(level: level))
                    .font(.system(size: UIScale.pt(15), weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(batteryColor(level: level))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(batteryDescription(level: level))
            .help(batteryDescription(level: level))
        }
    }

    private func batterySymbol(level: Int) -> String {
        if model.snapshot?.batteryPluggedIn == true { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(level: Int) -> Color {
        level < 20 && model.snapshot?.batteryPluggedIn != true
            ? DashSkin.danger : DashSkin.inkSoft(dark)
    }

    private func batteryDescription(level: Int) -> String {
        switch model.snapshot?.batteryPluggedIn {
        case true: "Battery \(level)%, plugged in"
        case false: "Battery \(level)%, on battery power"
        case nil: "Battery \(level)%"
        }
    }
}

struct MachineControlCenterView: View {
    let session: MachineSession
    @Bindable var model: MachineControlCenterModel
    @State private var confirmation: MachineControlConfirmation?
    @State private var hoveredRow: String?

    @Environment(\.colorScheme) private var scheme

    init(session: MachineSession) {
        self.session = session
        _model = Bindable(wrappedValue: MachineControlCenterModel(session: session))
    }

    init(model: MachineControlCenterModel) {
        session = model.session
        _model = Bindable(wrappedValue: model)
    }

    private var dark: Bool { scheme == .dark }
    private var snapshot: MachineControlSnapshot? { model.snapshot }
    private var profile: MachinePlatformProfile? { session.slow?.platformProfile }
    private var fans: [MachineFan] { session.slow?.fans ?? [] }
    private var hasControls: Bool { snapshot?.hasControlSettings ?? false }
    private var hasCooling: Bool { !fans.isEmpty || profile != nil }
    private var isBusy: Bool { model.isBusy }
    private var controlsDisabled: Bool { isBusy || !session.state.isConnected }
    private var busyLabel: String { model.isRefreshing ? "Refreshing" : "Updating" }
    private var scrollHeight: CGFloat {
        if !model.hasLoaded { return UIScale.pt(316) }
        if model.requiresConnection { return UIScale.pt(116) }
        if !hasControls, !hasCooling {
            return UIScale.pt(model.resultMessage == nil ? 86 : 104)
        }
        var height: CGFloat = 0
        if snapshot?.brightness != nil { height += 66 }
        if snapshot?.volume != nil { height += 66 }
        if snapshot?.muted != nil { height += 44 }
        if snapshot?.wifiEnabled != nil { height += 44 }
        if snapshot?.bluetoothEnabled != nil { height += 44 }
        if snapshot?.airplaneMode != nil { height += 44 }
        if snapshot?.doNotDisturb != nil { height += 44 }
        if snapshot?.keyboardBacklight != nil { height += 66 }
        if hasControls, hasCooling { height += 15 }
        if hasCooling {
            height += 22 + CGFloat(fans.count) * 36
            if profile != nil { height += 128 }
        }
        if model.resultMessage != nil { height += 44 }
        return UIScale.pt(min(max(height, 72), 520))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            header
            Divider().padding(.top, UIScale.pt(10))
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                    if !model.hasLoaded {
                        loadingState
                    } else if model.requiresConnection || (!hasControls && !hasCooling) {
                        unavailableState
                    } else {
                        availableControls
                        if let resultMessage = model.resultMessage {
                            Divider().padding(.leading, UIScale.pt(8))
                            resultRow(resultMessage)
                        }
                    }
                }
            }
            .frame(height: scrollHeight)
        }
        .padding(UIScale.pt(14))
        .frame(width: UIScale.pt(330))
        .onAppear { model.synchronizeProfileSelection() }
        .onChange(of: profile) { _, _ in model.synchronizeProfileSelection() }
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
            Text(session.machine.name)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
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
                Task { await model.refresh(reportFailure: true, clearsMessage: true) }
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
        VStack(spacing: UIScale.pt(0)) {
            ForEach(0..<6, id: \.self) { index in
                VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                    HStack(spacing: UIScale.pt(9)) {
                        SkeletonBlock(width: 18, height: 18, corner: 5)
                        SkeletonBlock(
                            width: index.isMultiple(of: 2) ? 86 : 112,
                            height: 10
                        )
                        Spacer(minLength: 0)
                        if index < 2 {
                            SkeletonBlock(width: 34, height: 9)
                        } else {
                            SkeletonBlock(width: 28, height: 16, corner: 8)
                        }
                    }
                    if index < 2 {
                        SkeletonBlock(height: 6, corner: 3)
                            .padding(.leading, UIScale.pt(27))
                    }
                }
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(index < 2 ? 17 : 13))
                if index < 5 {
                    Divider().padding(.leading, UIScale.pt(36))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading available controls")
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Label(
                model.requiresConnection
                    ? "Connect to discover controls"
                    : model.resultFailed ? "Controls unavailable" : "No controls available",
                systemImage: model.requiresConnection
                    ? "bolt.horizontal.circle"
                    : model.resultFailed ? "exclamationmark.triangle" : "switch.2"
            )
            .font(.system(size: UIScale.pt(12.5), weight: .medium))
            .foregroundStyle(model.resultFailed ? DashSkin.danger : DashSkin.ink(dark))
            Text(
                model.resultMessage
                    ?? (model.requiresConnection
                        ? "Reconnect this machine to check its available settings."
                        : "This machine did not report any supported controls.")
            )
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            if model.requiresConnection {
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
                "Brightness", symbol: "sun.max", value: $model.brightness,
                onCommit: {
                    model.perform(
                        .setBrightness(model.brightness), success: "Brightness updated")
                })
        }
        if snapshot?.volume != nil {
            if hasControl(before: 1) { controlDivider }
            sliderRow(
                "Volume", symbol: "speaker.wave.2", value: $model.volume,
                onCommit: {
                    model.perform(.setVolume(model.volume), success: "Volume updated")
                })
        }
        if snapshot?.muted != nil {
            if hasControl(before: 2) { controlDivider }
            toggleRow(
                "Mute", symbol: model.muted ? "speaker.slash.fill" : "speaker.slash",
                value: model.muted
            ) {
                model.muted = $0
                model.perform(.setMuted($0), success: $0 ? "Audio muted" : "Audio unmuted")
            }
        }
        if snapshot?.wifiEnabled != nil {
            if hasControl(before: 3) { controlDivider }
            toggleRow("Wi-Fi", symbol: "wifi", value: model.wifiEnabled) { next in
                if next {
                    model.wifiEnabled = true
                    model.perform(.setWiFiEnabled(true), success: "Wi-Fi turned on")
                } else {
                    confirmation = .disableWiFi
                }
            }
        }
        if snapshot?.bluetoothEnabled != nil {
            if hasControl(before: 4) { controlDivider }
            toggleRow("Bluetooth", symbol: "wave.3.right", value: model.bluetoothEnabled) {
                model.bluetoothEnabled = $0
                model.perform(
                    .setBluetoothEnabled($0),
                    success: $0 ? "Bluetooth turned on" : "Bluetooth turned off")
            }
        }
        if snapshot?.airplaneMode != nil {
            if hasControl(before: 5) { controlDivider }
            toggleRow("Airplane mode", symbol: "airplane", value: model.airplaneMode) { next in
                if next {
                    confirmation = .enableAirplaneMode
                } else {
                    model.airplaneMode = false
                    model.perform(
                        .setAirplaneMode(false), success: "Airplane mode turned off")
                }
            }
        }
        if snapshot?.doNotDisturb != nil {
            if hasControl(before: 6) { controlDivider }
            toggleRow(
                "Do Not Disturb", symbol: "moon.fill", value: model.doNotDisturb
            ) {
                model.doNotDisturb = $0
                model.perform(
                    .setDoNotDisturb($0),
                    success: $0 ? "Do Not Disturb turned on" : "Do Not Disturb turned off")
            }
        }
        if snapshot?.keyboardBacklight != nil {
            if hasControl(before: 7) { controlDivider }
            sliderRow(
                "Keyboard lighting", symbol: "keyboard", value: $model.keyboardBacklight,
                onCommit: {
                    model.perform(
                        .setKeyboardBacklight(model.keyboardBacklight),
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
                Picker("Profile", selection: $model.selectedProfile) {
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
                Picker("Duration", selection: $model.duration) {
                    ForEach(MachineProfileDuration.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: UIScale.pt(92))
                .disabled(controlsDisabled)
                .pointerCursor()
                Button("Apply") { model.applyProfile() }
                    .controlSize(.small)
                    .disabled(model.selectedProfile.isEmpty || controlsDisabled)
                    .pointerCursor()
            }
            HStack(spacing: UIScale.pt(8)) {
                Text(profileStatus(profile))
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(9))
    }

    private func resultRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(7)) {
            Image(
                systemName: model.resultFailed
                    ? "exclamationmark.triangle" : "checkmark.circle.fill"
            )
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            Text(message)
                .font(.system(size: UIScale.pt(10.5)))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(model.resultFailed ? DashSkin.danger : DashSkin.sage)
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

    private func applyConfirmedNetworkChange() {
        let confirmed = confirmation
        confirmation = nil
        switch confirmed {
        case .disableWiFi:
            model.wifiEnabled = false
            model.perform(.setWiFiEnabled(false), success: "Wi-Fi turned off")
        case .enableAirplaneMode:
            model.airplaneMode = true
            model.perform(.setAirplaneMode(true), success: "Airplane mode turned on")
        case nil:
            break
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

    private func profileLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
