import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UserNotifications

private struct ClaudeStatusLineRow: View {
    @Environment(\.usageUIClient) private var client
    @State private var connected: Bool?
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        LabeledContent("Claude Code status line") {
            HStack(spacing: 8) {
                if let failure {
                    Text(failure).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Text(connected == true ? "Connected" : "Not connected")
                    .foregroundStyle(.secondary)
                Button(connected == true ? "Disconnect" : "Connect") { toggle() }
                    .disabled(connected == nil)
            }
        }
        .onDisappear {
            operation?.cancel(); operation = nil
        }
        .pageTask {
            let result: Bool
            if let client {
                result =
                    (try? await client.value(
                        "usage.statusline.status", as: UsageStatusLineStatusResponse.self))?
                    .installed ?? false
            } else {
                result = await ClaudeStatusLine.isConnected()
            }
            guard !Task.isCancelled else { return }
            connected = result
        }
    }

    private func toggle() {
        let connect = connected != true
        failure = nil
        operation?.cancel()
        operation = Task {
            do {
                let change: ClaudeStatusLine.Change
                if let client {
                    let reply: UsageStatusLineChangeResponse = try await client.value(
                        connect ? "usage.statusline.install" : "usage.statusline.remove")
                    guard let value = ClaudeStatusLine.Change(rawValue: reply.change) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    change = value
                } else {
                    change = try await ClaudeStatusLine.setConnected(connect)
                }
                guard !Task.isCancelled else { return }
                connected = change != .removed && change != .restored && change != .absent
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct UsageSettingsRows: View {
    @Environment(\.usageUIClient) private var client
    private let enabled = true
    @AppStorage(AppStorageKeys.Limits.inMenuBar, store: SharedDefaults.store) private
        var limitsInMenuBar = true
    @AppStorage(AppStorageKeys.Limits.claudeEnabled, store: SharedDefaults.store) private
        var claudeEnabled = true
    @AppStorage(AppStorageKeys.Limits.codexEnabled, store: SharedDefaults.store) private
        var codexEnabled = true
    @AppStorage(AppStorageKeys.Limits.cursorEnabled, store: SharedDefaults.store) private
        var cursorEnabled = true
    @AppStorage(AppStorageKeys.Limits.grokEnabled, store: SharedDefaults.store) private
        var grokEnabled = true
    @AppStorage(AppStorageKeys.Limits.provider, store: SharedDefaults.store) private
        var limitsProviderRaw =
        LimitProvider.claude.rawValue
    @AppStorage(AppStorageKeys.MenuBar.colorMode, store: SharedDefaults.store) private
        var menuBarColorMode =
        "auto"
    @AppStorage(AppStorageKeys.MenuBar.claudeWindows, store: SharedDefaults.store) private
        var claudeWindowsRaw = "session,week,fable"
    @AppStorage(AppStorageKeys.MenuBar.codexWindows, store: SharedDefaults.store) private
        var codexWindowsRaw = "session,week"
    @AppStorage(AppStorageKeys.MenuBar.cursorWindows, store: SharedDefaults.store) private
        var cursorWindowsRaw = "session,week"
    @AppStorage(AppStorageKeys.MenuBar.grokWindows, store: SharedDefaults.store) private
        var grokWindowsRaw = "week"
    @AppStorage(AppStorageKeys.MenuBar.limitsStyle, store: SharedDefaults.store) private
        var limitsStyleRaw = "stacked"
    @AppStorage(AppStorageKeys.General.smartColor, store: SharedDefaults.store) private
        var smartColor = true
    @AppStorage(AppStorageKeys.MenuBar.subColorHex, store: SharedDefaults.store) private
        var subColorHex =
        "8E8E93"
    @AppStorage(AppStorageKeys.MenuBar.lowColorHex, store: SharedDefaults.store) private
        var lowColorHex =
        "34C759"
    @AppStorage(AppStorageKeys.MenuBar.midColorHex, store: SharedDefaults.store) private
        var midColorHex =
        "FF9500"
    @AppStorage(AppStorageKeys.MenuBar.highColorHex, store: SharedDefaults.store) private
        var highColorHex =
        "FF3B30"
    @AppStorage(AppStorageKeys.Limits.warnPercent, store: SharedDefaults.store) private
        var warnPercent = LimitRing.defaultWarnPercent
    @AppStorage(AppStorageKeys.Limits.critPercent, store: SharedDefaults.store) private
        var critPercent = LimitRing.defaultCriticalPercent
    @AppStorage(AppStorageKeys.Limits.pacingMargin, store: SharedDefaults.store) private
        var pacingMargin = 10.0
    @AppStorage(AppStorageKeys.Budget.enabled, store: SharedDefaults.store) private
        var budgetEnabled = false
    @AppStorage(AppStorageKeys.Budget.mode, store: SharedDefaults.store) private var budgetMode =
        "pace"
    @AppStorage(AppStorageKeys.Budget.kind, store: SharedDefaults.store) private var budgetKind =
        "weekly"
    @AppStorage(AppStorageKeys.Budget.capPercent, store: SharedDefaults.store) private
        var budgetCap = 50.0
    @AppStorage(AppStorageKeys.Budget.deadline, store: SharedDefaults.store) private
        var budgetDeadlineTS = 0.0
    @AppStorage(AppStorageKeys.Notify.master, store: SharedDefaults.store) private
        var notifyMaster = false
    @AppStorage(AppStorageKeys.Notify.trackSession, store: SharedDefaults.store) private
        var trackSession = true
    @AppStorage(AppStorageKeys.Notify.trackWeekly, store: SharedDefaults.store) private
        var trackWeekly = true
    @AppStorage(AppStorageKeys.Notify.onPace, store: SharedDefaults.store) private var onPace =
        true
    @AppStorage(AppStorageKeys.Notify.almostCapped, store: SharedDefaults.store) private
        var almostCapped = true
    @AppStorage(AppStorageKeys.Notify.almostCappedPercent, store: SharedDefaults.store) private
        var almostCappedPercent = LimitAlertSettings.defaultAlmostCappedPercent
    @AppStorage(AppStorageKeys.Notify.capped, store: SharedDefaults.store) private var capped =
        true
    @AppStorage(AppStorageKeys.Notify.back, store: SharedDefaults.store) private var back = true
    @AppStorage(AppStorageKeys.Notify.outlook, store: SharedDefaults.store) private var outlook =
        false
    @AppStorage(AppStorageKeys.Notify.headroom, store: SharedDefaults.store) private
        var headroom = false
    @AppStorage(AppStorageKeys.Notify.loginProblems, store: SharedDefaults.store) private
        var loginProblems = true
    @State private var projections: [String] = []
    @State private var testSent = false
    @State private var testMessage: String?
    @State private var notificationTest: Task<Void, Never>?
    @State private var notificationPermission: Task<Void, Never>?

    private var hasProvider: Bool { claudeEnabled || codexEnabled || cursorEnabled || grokEnabled }

    var body: some View {
        UsageMachineSettingsRows()
        Section {
            Group {
                Toggle(
                    "Claude limits",
                    isOn: $claudeEnabled
                )
                if claudeEnabled {
                    ClaudeStatusLineRow()
                }
                Toggle(
                    "Codex limits",
                    isOn: $codexEnabled
                )
                Toggle(
                    "Cursor limits",
                    isOn: $cursorEnabled
                )
                Toggle(
                    "Grok allowance",
                    isOn: $grokEnabled
                )
                Toggle(
                    "Show limits in the menu bar",
                    isOn: $limitsInMenuBar
                )

                if limitsInMenuBar {
                    if claudeEnabled {
                        LimitWindowChipsRow(
                            title: "Claude shows", provider: .claude,
                            raw: $claudeWindowsRaw)
                    }
                    if codexEnabled {
                        LimitWindowChipsRow(
                            title: "Codex shows", provider: .codex,
                            raw: $codexWindowsRaw)
                    }
                    if cursorEnabled {
                        LimitWindowChipsRow(
                            title: "Cursor shows", provider: .cursor,
                            raw: $cursorWindowsRaw)
                    }
                    if grokEnabled {
                        LimitWindowChipsRow(
                            title: "Grok shows", provider: .grok,
                            raw: $grokWindowsRaw)
                    }
                    Picker(
                        "Style",
                        selection: $limitsStyleRaw
                    ) {
                        Text("Stacked").tag("stacked")
                        Text("Tagged").tag("tagged")
                        Text("Slashes").tag("slash")
                    }

                    Picker("Color", selection: colorModeBinding) {
                        Text("Automatic").tag("auto")
                        Text("Custom").tag("custom")
                    }

                    if isCustomColor {
                        ColorPicker(
                            "Text (5h / 7d)",
                            selection: hexBinding(
                                $subColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "Low risk",
                            selection: hexBinding(
                                $lowColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "Medium risk",
                            selection: hexBinding(
                                $midColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "High risk",
                            selection: hexBinding(
                                $highColorHex),
                            supportsOpacity: false)
                        Toggle(
                            "Smart color",
                            isOn: $smartColor
                        )
                        if smartColor {
                            HStack {
                                Text("Pacing margin")
                                Spacer()
                                Stepper(
                                    "±\(Int(pacingMargin)) pp",
                                    value: $pacingMargin,
                                    in: 5...25, step: 5
                                )
                            }
                        } else {
                            HStack {
                                Text("Thresholds")
                                Spacer()
                                Stepper(
                                    "Warn \(warnPercent)%",
                                    value: $warnPercent,
                                    in: 10...critPercent - 5, step: 5
                                )
                                Stepper(
                                    "Critical \(critPercent)%",
                                    value: $critPercent,
                                    in: warnPercent + 5...100, step: 5
                                )
                            }
                        }
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            if !hasProvider {
                Label("Agent Usage is paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text(
                    "Turn on Agent Usage above to restore \(selectedProvider.label) limits. Menu bar limits and alerts are off."
                )
                .settingsCaption()
            }
        } header: {
            Text("Readout styling")
        } footer: {
            if limitsInMenuBar {
                Text(
                    isCustomColor
                        ? "The percentage shifts from Low to High risk as usage climbs. Smart color drives that shift by time-aware pacing instead of the raw percentage."
                        : "White and Black force a single tint. Pick Custom to color by risk stage."
                )
                .font(.system(size: UIScale.pt(10)))
            }
        }

        Section {
            Toggle(
                "Pace my Claude usage",
                isOn: $budgetEnabled
            )
            Text(
                "Set a personal cap under the real limit and get told if you're spending too fast."
            )
            .settingsCaption()
            if budgetEnabled {
                Picker(
                    "Mode", selection: $budgetMode
                ) {
                    Text("Auto daily pace").tag("pace")
                    Text("Cap by a deadline").tag("cap")
                }
                Picker(
                    "Window", selection: $budgetKind
                ) {
                    Text("Weekly").tag("weekly")
                    Text("Session (5h)").tag("session")
                }
                HStack {
                    Text("Cap")
                    Slider(
                        value: $budgetCap,
                        in: 10...100, step: 5)
                    Text("\(Int(budgetCap))%").monospacedDigit().frame(
                        width: UIScale.pt(40), alignment: .trailing)
                }
                if budgetMode == "cap" {
                    DatePicker(
                        "Stay under until",
                        selection: Binding(
                            get: {
                                budgetDeadlineTS > 0
                                    ? Date(timeIntervalSinceReferenceDate: budgetDeadlineTS)
                                    : Date().addingTimeInterval(2 * 86400)
                            },
                            set: {
                                $budgetDeadlineTS
                                    .wrappedValue = $0.timeIntervalSinceReferenceDate
                            }),
                        displayedComponents: [.date, .hourAndMinute])
                }
            }
        } header: {
            Text("Budget and pacing")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        Section {
            Toggle("Enable alerts", isOn: alertsBinding)
            Group {
                LimitAlertToggle(
                    "5-hour windows", detail: "Alerts for Claude and Codex 5-hour limits.",
                    isOn: $trackSession)
                LimitAlertToggle(
                    "Weekly windows",
                    detail:
                        "Alerts for weekly limits, Fable included, Cursor's billing-cycle pools, and Grok's allowance.",
                    isOn: $trackWeekly)
                LimitAlertToggle(
                    "On pace to hit the cap",
                    detail:
                        "When your recent burn would hit the cap before the window resets, with the time it would.",
                    isOn: $onPace)
                HStack {
                    LimitAlertToggle(
                        "Almost capped",
                        detail: "Once per window when usage crosses the line, with what is left.",
                        isOn: $almostCapped
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: UIScale.pt(6)) {
                        Text("\(almostCappedPercent)%").monospacedDigit()
                        Stepper(
                            "Almost capped at \(almostCappedPercent) percent",
                            value: $almostCappedPercent,
                            in: LimitAlertSettings.almostCappedRange, step: 5
                        )
                        .labelsHidden()
                    }
                    .fixedSize()
                    .disabled(!almostCapped)
                }
                LimitAlertToggle(
                    "Capped", detail: "When a window hits 100%, with the time it comes back.",
                    isOn: $capped)
                LimitAlertToggle(
                    "Back after a reset",
                    detail: "At the reset of a window that was capped or nearly capped.",
                    isOn: $back)
                LimitAlertToggle(
                    "Weekly outlook",
                    detail: "A morning note when a week is heading for a tight finish.",
                    isOn: $outlook)
                LimitAlertToggle(
                    "Unused headroom",
                    detail: "On the last day of a weekly window when half or more is unused.",
                    isOn: $headroom)
                LimitAlertToggle(
                    "Login problems",
                    detail: "Once when a provider login breaks, again only after it recovers.",
                    isOn: $loginProblems)
            }
            .disabled(!notifyMaster)
            .opacity(notifyMaster ? 1 : 0.5)

            ForEach(projections, id: \.self) { line in
                Text(line).settingsCaption()
            }

            HStack {
                Button("Send test notification") {
                    notificationTest?.cancel()
                    testSent = true
                    notificationTest = Task {
                        let result: String
                        if let client = client {
                            result =
                                (try? await client.value(
                                    "usage.ui.notifications.test", as: String.self))
                                ?? "Notification test failed"
                        } else {
                            result = await LimitNotifier.shared.sendTest()
                        }
                        guard !Task.isCancelled else { return }
                        testMessage = result
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        testSent = false
                        notificationTest = nil
                    }
                }
                if testSent {
                    Text(testMessage ?? "Sending test notification")
                        .settingsCaption()
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text(
                "Alerts use your local clock and fire once per window. With Jev enabled, on-pace, outlook and headroom alerts only go out when Jev thinks they are worth the interruption."
            )
            .font(.system(size: UIScale.pt(10)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onDisappear {
            notificationTest?.cancel(); notificationTest = nil
            notificationPermission?.cancel(); notificationPermission = nil
        }
        .pageTask(id: notifyMaster) {
            let result: [String]
            if let client {
                result = (try? await client.value("usage.ui.alerts", as: [String].self)) ?? []
            } else {
                result = await LimitAlertInspector.previewLines()
            }
            guard !Task.isCancelled else { return }
            projections = result
        }
        .onChange(of: claudeEnabled) { reconcileProviders() }
        .onChange(of: codexEnabled) { reconcileProviders() }
        .onChange(of: cursorEnabled) { reconcileProviders() }
        .onChange(of: grokEnabled) { reconcileProviders() }
    }

    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { notifyMaster },
            set: { enabled in
                $notifyMaster.wrappedValue = enabled
                if enabled {
                    notificationPermission?.cancel()
                    notificationPermission = Task {
                        if let client = client {
                            _ = try? await client.invoke("usage.ui.notifications.authorize")
                        } else {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                                options: [.alert, .sound, .badge])
                        }
                    }
                }
            })
    }

    private var isCustomColor: Bool {
        menuBarColorMode == "custom"
    }

    private var colorModeBinding: Binding<String> {
        Binding(
            get: { isCustomColor ? "custom" : "auto" },
            set: {
                $menuBarColorMode.wrappedValue = $0
            })
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { DashPalette.color(hex.wrappedValue) },
            set: { hex.wrappedValue = $0.hex6 })
    }

    private var selectedProvider: LimitProvider {
        LimitProvider(rawValue: limitsProviderRaw) ?? .claude
    }

    private func reconcileProviders() {
        UsageWorkerOperations.controller?.settingsChanged()

    }
}

private struct LimitAlertToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                Text(detail).settingsCaption()
            }
        }
    }
}

private struct LimitWindowChipsRow: View {
    let title: String
    let provider: LimitProvider
    @Binding var raw: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(MenuBarLimits.slots(for: provider), id: \.self) { slot in
                Toggle(slot.settingsLabel(for: provider), isOn: binding(for: slot))
                    .toggleStyle(.button)
            }
        }
    }

    private func binding(for slot: LimitWindowSlot) -> Binding<Bool> {
        Binding(
            get: { MenuBarLimits.parseSelection(raw, provider: provider).contains(slot) },
            set: { on in
                var current = Set(MenuBarLimits.parseSelection(raw, provider: provider))
                if on { current.insert(slot) } else { current.remove(slot) }
                raw = MenuBarLimits.encodeSelection(
                    MenuBarLimits.slots(for: provider).filter(current.contains))
            })
    }
}
