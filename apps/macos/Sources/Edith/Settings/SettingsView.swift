import AppKit
import Carbon.HIToolbox
import SwiftUI

let themePalette: [(name: String, color: Color)] = [
    ("blue", .blue), ("indigo", .indigo), ("teal", .teal), ("green", .green),
    ("purple", .purple), ("pink", .pink), ("red", .red), ("orange", .orange),
]

func themeColor(_ name: String) -> Color {
    if name == "accent" { return .accentColor }
    return themePalette.first { $0.name == name }?.color ?? .accentColor
}

struct SettingsView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("presenterMode") private var presenter = false
    @AppStorage("theme") private var themeName = "accent"
    @AppStorage("lastPaletteTheme") private var lastPaletteTheme = "blue"
    @AppStorage("appearance") private var appearance = "system"
    @State private var draggingTab: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowPitch: CGFloat = 46
    @AppStorage("tabUsageEnabled") private var usageEnabled = true
    @AppStorage("tabMusicEnabled") private var musicEnabled = true
    @AppStorage("tabSystemEnabled") private var systemEnabled = true
    @AppStorage("tabCalendarEnabled") private var calendarEnabled = true
    @AppStorage("tabOrder") private var tabOrderRaw = "usage,music,system"
    @AppStorage("icloudBackup") private var icloudBackup = false
    @AppStorage("lastBackupAt") private var lastBackupAt = 0.0
    @AppStorage("musicBackup") private var musicBackup = false
    @AppStorage("lastMusicBackupAt") private var lastMusicBackupAt = 0.0
    @AppStorage("backupSettings") private var backupSettings = true
    @AppStorage("backupUsage") private var backupUsage = true
    @AppStorage("backupLimits") private var backupLimits = true
    @State private var showBackupDetail = false
    @State private var settingsSize = ""
    @State private var usageSize = ""
    @State private var limitsSize = ""
    @ObservedObject private var backupService = SettingsBackup.shared
    @State private var musicSize = ""
    @AppStorage("limitsInMenuBar") private var limitsInMenuBar = true
    @AppStorage("menuBarColorMode") private var menuBarColorMode = "auto"
    @AppStorage("smartColor") private var smartColor = true
    @AppStorage("warnPercent") private var warnPercent = 60
    @AppStorage("critPercent") private var critPercent = 85
    @AppStorage("pacingMargin") private var pacingMargin = 10.0
    @AppStorage("notifyMaster") private var notifyMaster = false
    @AppStorage("notifyTrackSession") private var notifyTrackSession = true
    @AppStorage("notifyTrackWeekly") private var notifyTrackWeekly = true
    @AppStorage("notifyRecovery") private var notifyRecovery = true
    @AppStorage("notifyPacingWarning") private var notifyPacingWarning = true
    @AppStorage("notifyPacingHot") private var notifyPacingHot = true
    @AppStorage("notifyReminderSession") private var reminderSession = false
    @AppStorage("notifyReminderSessionOffsetMin") private var reminderSessionOffset = 30
    @AppStorage("notifyReminderWeekly") private var reminderWeekly = false
    @AppStorage("notifyReminderWeeklyOffsetMin") private var reminderWeeklyOffset = 120
    @AppStorage("notifyTokenExpired") private var notifyTokenExpired = true
    @State private var notifDenied = false
    @State private var showAllNotifSettings = false
    @State private var showAllLimitSettings = false
    @State private var testResult: String?

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("TABS")
                let order = orderedTabIDs(tabOrderRaw)
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    if let info = allTabs.first(where: { $0.id == id }) {
                        tabRow(info)
                            .offset(y: rowOffset(index: index, id: id, order: order))
                            .zIndex(draggingTab == id ? 1 : 0)
                            .animation(
                                draggingTab == id ? nil : .easeOut(duration: 0.15),
                                value: projectedDelta)
                    }
                }
            }
            .card()
            .onChange(of: usageEnabled) { services.sync() }
            .onChange(of: musicEnabled) { services.sync() }
            .onChange(of: systemEnabled) { services.sync() }
            .onChange(of: calendarEnabled) { services.sync() }

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("GENERAL")
                HStack {
                    Text("Presenter view")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $presenter)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(theme)
                        .pointerCursor()
                }
                HStack {
                    Text("Toggle shortcut")
                        .font(.system(size: 13))
                    Spacer()
                    ShortcutRecorder()
                }
                HStack {
                    Text("Appearance")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .pointerCursor()
                    .onChange(of: appearance) { applyAppearance(appearance) }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("LIMITS")
                toggleRow(
                    "Show in menu bar",
                    subtitle: "Session + weekly percentages next to the clock",
                    isOn: $limitsInMenuBar)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu bar color").font(.system(size: 13))
                        Text("Auto tints the numbers by risk")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker("", selection: $menuBarColorMode) {
                        Text("Auto").tag("auto")
                        Text("White").tag("white")
                        Text("Black").tag("black")
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
                }
                toggleRow(
                    "Smart color",
                    subtitle: "Time-aware risk drives colors and alerts",
                    isOn: $smartColor)
                if showAllLimitSettings {
                    HStack {
                        Text("Warning / critical").font(.system(size: 13))
                        Spacer()
                        Stepper(
                            "\(warnPercent)%", value: $warnPercent, in: 10...critPercent - 5,
                            step: 5
                        )
                        .font(.system(size: 12)).fixedSize().pointerCursor()
                        Stepper(
                            "\(critPercent)%", value: $critPercent, in: warnPercent + 5...100,
                            step: 5
                        )
                        .font(.system(size: 12)).fixedSize().pointerCursor()
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pacing margin").font(.system(size: 13))
                            Text("How far ahead of even pace counts as drifting")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Stepper(
                            "±\(Int(pacingMargin))pp", value: $pacingMargin, in: 5...25, step: 5
                        )
                        .font(.system(size: 12)).fixedSize().pointerCursor()
                    }
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAllLimitSettings.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAllLimitSettings ? "View less" : "View more")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showAllLimitSettings ? 180 : 0))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .frame(maxWidth: .infinity)
            }
            .card()
            .onChange(of: limitsInMenuBar) { services.usage?.syncStatusItem() }
            .onChange(of: menuBarColorMode) { services.usage?.refreshMenuBarItem() }
            .onChange(of: smartColor) { services.usage?.refreshMenuBarItem() }
            .onChange(of: warnPercent) { services.usage?.refreshMenuBarItem() }
            .onChange(of: critPercent) { services.usage?.refreshMenuBarItem() }
            .onChange(of: pacingMargin) { services.usage?.refreshMenuBarItem() }

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("NOTIFICATIONS")
                toggleRow(
                    "Enable notifications",
                    subtitle: notifDenied
                        ? "Denied in System Settings > Notifications > Edith"
                        : "Alerts for limit levels, pacing, resets",
                    isOn: $notifyMaster)
                if showAllNotifSettings {
                    Group {
                        toggleRow("Session (5h) alerts", isOn: $notifyTrackSession)
                        toggleRow("Weekly alerts", isOn: $notifyTrackWeekly)
                        toggleRow("Recovery (back to green)", isOn: $notifyRecovery)
                        toggleRow("Pacing: drifting fast", isOn: $notifyPacingWarning)
                        toggleRow("Pacing: burning hot", isOn: $notifyPacingHot)
                        toggleRow("Token expired", isOn: $notifyTokenExpired)
                        HStack {
                            toggleRow("Remind before session reset", isOn: $reminderSession)
                            Picker("", selection: $reminderSessionOffset) {
                                Text("5 min").tag(5); Text("15 min").tag(15)
                                Text("30 min").tag(30); Text("1 h").tag(60)
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
                            .disabled(!reminderSession)
                        }
                        HStack {
                            toggleRow("Remind before weekly reset", isOn: $reminderWeekly)
                            Picker("", selection: $reminderWeeklyOffset) {
                                Text("1 h").tag(60); Text("2 h").tag(120)
                                Text("6 h").tag(360); Text("12 h").tag(720)
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
                            .disabled(!reminderWeekly)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Button("Send test notification") {
                                testResult = "Sending..."
                                Task { testResult = await services.usage?.notifier.sendTest() }
                            }
                            .buttonStyle(HoverButtonStyle())
                            .font(.system(size: 12))
                            .foregroundStyle(theme)
                            if let testResult {
                                Text(testResult)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .disabled(!notifyMaster)
                    .opacity(notifyMaster ? 1 : 0.45)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAllNotifSettings.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAllNotifSettings ? "View less" : "View more")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showAllNotifSettings ? 180 : 0))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .frame(maxWidth: .infinity)
            }
            .card()
            .onChange(of: notifyMaster) {
                if notifyMaster {
                    services.usage?.notifier.requestPermission()
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        notifDenied =
                            await services.usage?.notifier.authorizationStatus() == .denied
                    }
                } else {
                    services.usage?.notifier.cancelReminders()
                }
            }
            .task {
                notifDenied = await services.usage?.notifier.authorizationStatus() == .denied
            }

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("THEME")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use system accent")
                            .font(.system(size: 13))
                        Text("Follows the accent color in System Settings")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { themeName == "accent" },
                            set: { themeName = $0 ? "accent" : lastPaletteTheme }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(theme)
                    .pointerCursor()
                }
                HStack(spacing: 11) {
                    ForEach(themePalette, id: \.name) { entry in
                        swatch(entry.name, color: entry.color, help: entry.name.capitalized)
                    }
                    Spacer()
                }
                .opacity(themeName == "accent" ? 0.4 : 1)
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("DATA")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App data")
                            .font(.system(size: 13))
                        Text("~/Library/Application Support/Edith")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(AppData.supportDir)
                        dismissPanel()
                    }
                    .buttonStyle(HoverButtonStyle())
                    .font(.system(size: 12))
                    .foregroundStyle(theme)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showBackupDetail.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showBackupDetail ? 90 : 0))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Back up to iCloud").font(.system(size: 13))
                                    Text(backupSubtitle).font(.system(size: 10)).foregroundStyle(
                                        .tertiary)
                                }
                            }
                        }
                        .buttonStyle(HoverButtonStyle())
                        Spacer()
                        Toggle("", isOn: $icloudBackup)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .tint(theme).pointerCursor().disabled(!AppData.cloudAvailable)
                    }
                    if showBackupDetail {
                        Group {
                            backupFileRow(
                                "Settings", file: "settings.json", size: settingsSize,
                                isOn: $backupSettings)
                            backupFileRow(
                                "Usage", file: "usage.json", size: usageSize, isOn: $backupUsage)
                            backupFileRow(
                                "Session history", file: "limits-history.jsonl", size: limitsSize,
                                isOn: $backupLimits)
                        }
                        .padding(.leading, 16)
                        .disabled(!icloudBackup)
                        .opacity(icloudBackup ? 1 : 0.45)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back up music to iCloud")
                            .font(.system(size: 13))
                        Text(musicSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $musicBackup)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(theme)
                        .pointerCursor()
                        .disabled(!AppData.cloudAvailable)
                }
            }
            .card()
            .onChange(of: icloudBackup) {
                if icloudBackup { SettingsBackup.shared.export(); SettingsBackup.shared.syncData() }
            }
            .onChange(of: backupSettings) { if icloudBackup { SettingsBackup.shared.export() } }
            .onChange(of: backupUsage) { if icloudBackup { SettingsBackup.shared.syncData() } }
            .onChange(of: backupLimits) { if icloudBackup { SettingsBackup.shared.syncData() } }
            .onChange(of: musicBackup) {
                if musicBackup { SettingsBackup.shared.backupMusic() }
            }
            .onAppear {
                computeMusicSize(); computeDataSizes()
            }

            HStack(spacing: 4) {
                Text("Made with ❤️ by")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button("Pulkit") {
                    NSWorkspace.shared.open(URL(string: "https://pulkit.page")!)
                    dismissPanel()
                }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme)
                .help("pulkit.page")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    private func swatch(_ name: String, color: Color, help: String) -> some View {
        Button {
            themeName = name
            lastPaletteTheme = name
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                if themeName == name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }

    private var musicSubtitle: String {
        if !AppData.cloudAvailable { return "iCloud Drive is not available on this Mac" }
        var parts: [String] = [musicSize.isEmpty ? "measuring…" : "\(musicSize) in local/music"]
        if backupService.musicBackupRunning {
            parts.append("backing up…")
        } else if musicBackup, lastMusicBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastMusicBackupAt)
            parts.append("backed up \(at.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func computeMusicSize() {
        Task.detached(priority: .utility) {
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: Repo.musicDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let total = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let label = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            await MainActor.run { musicSize = label }
        }
    }

    private var backupSubtitle: String {
        if !AppData.cloudAvailable { return "iCloud Drive is not available on this Mac" }
        if !icloudBackup { return "Syncs via iCloud Drive; newest copy wins across Macs" }
        if lastBackupAt > 0 {
            let at = Date(timeIntervalSince1970: lastBackupAt)
            return "Backed up \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Waiting for first backup…"
    }

    private func tabRow(_ info: TabInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(
                    draggingTab == info.id ? AnyShapeStyle(theme) : AnyShapeStyle(.tertiary)
                )
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
                .onHover { over in
                    over ? NSCursor.openHand.set() : NSCursor.arrow.set()
                }
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            if draggingTab == nil {
                                draggingTab = info.id
                                NSCursor.closedHand.set()
                            }
                            dragTranslation = value.translation.height
                        }
                        .onEnded { _ in commitDrag() }
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 13))
                Text(info.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: tabBinding(info.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(theme)
                .pointerCursor()
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(draggingTab == info.id ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
        )
        .scaleEffect(draggingTab == info.id ? 1.02 : 1)
        .shadow(color: .black.opacity(draggingTab == info.id ? 0.3 : 0), radius: 6, y: 2)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { rowPitch = geo.size.height + 12 }
            })
    }

    private var projectedDelta: Int {
        guard rowPitch > 0 else { return 0 }
        return Int((dragTranslation / rowPitch).rounded())
    }

    private func rowOffset(index: Int, id: String, order: [String]) -> CGFloat {
        guard let dragging = draggingTab,
            let from = order.firstIndex(of: dragging)
        else { return 0 }
        if id == dragging { return dragTranslation }
        let to = max(0, min(order.count - 1, from + projectedDelta))
        if from < to, index > from, index <= to { return -rowPitch }
        if to < from, index >= to, index < from { return rowPitch }
        return 0
    }

    private func commitDrag() {
        defer {
            withAnimation(.easeOut(duration: 0.18)) {
                draggingTab = nil
                dragTranslation = 0
            }
            NSCursor.arrow.set()
        }
        guard let dragging = draggingTab else { return }
        var order = orderedTabIDs(tabOrderRaw)
        guard let from = order.firstIndex(of: dragging) else { return }
        let to = max(0, min(order.count - 1, from + projectedDelta))
        guard to != from else { return }
        let item = order.remove(at: from)
        order.insert(item, at: to)
        tabOrderRaw = order.joined(separator: ",")
    }

    private func tabBinding(_ id: String) -> Binding<Bool> {
        switch id {
        case "usage": $usageEnabled
        case "music": $musicEnabled
        case "system": $systemEnabled
        case "calendar": $calendarEnabled
        default: .constant(false)
        }
    }

    private func backupFileRow(_ title: String, file: String, size: String, isOn: Binding<Bool>)
        -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(size.isEmpty ? file : "\(file) · \(size)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(theme).pointerCursor()
                .disabled(!AppData.cloudAvailable)
        }
    }

    private func computeDataSizes() {
        Task.detached(priority: .utility) {
            let fmt = { (url: URL) -> String in
                guard let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                    return "—"
                }
                return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
            }
            let s = fmt(AppData.supportDir.appendingPathComponent("settings.json"))
            let u = fmt(Repo.usageJSON)
            let l = fmt(LimitsHistory.url)
            await MainActor.run {
                settingsSize = s; usageSize = u; limitsSize = l
            }
        }
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>)
        -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(theme).pointerCursor()
        }
    }
}

struct ShortcutRecorder: View {
    static var isRecording = false

    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = HotKey.label

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : label)
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(
                    .primary.opacity(recording ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(HoverButtonStyle())
        .onDisappear { if recording { stop() } }
        .help("Click, then press the new shortcut (Esc cancels)")
    }

    private func start() {
        recording = true
        Self.isRecording = true
        HotKey.unregister()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.className.contains("MenuBarExtraWindow") }?
            .makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        Self.isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        HotKey.register()
        label = HotKey.label
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        else { return }
        var mods = 0
        var symbols = ""
        if flags.contains(.control) { mods |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { mods |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { mods |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { mods |= cmdKey; symbols += "⌘" }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        HotKey.save(code: Int(event.keyCode), mods: mods, label: symbols + key)
        stop()
    }
}
