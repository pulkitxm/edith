import AppKit
import Combine
import EdithKit
import SwiftUI

enum ExtensionPermissionState {
    static func readGrantedPermissions() -> [ExtensionPermission: Bool] {
        Dictionary(
            uniqueKeysWithValues: ExtensionPermission.allCases.map { permission in
                let granted: Bool
                if let key = permission.grantedDefaultsKey {
                    granted = SharedDefaults.store.bool(forKey: key)
                } else {
                    granted = false
                }
                return (permission, granted)
            })
    }
}

struct ExtensionsPane: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = false
    @AppStorage("claudeLimitsEnabled", store: SharedDefaults.store) private var claudeEnabled = true
    @AppStorage("codexLimitsEnabled", store: SharedDefaults.store) private var codexEnabled = true
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true
    @AppStorage("notifyMaster", store: SharedDefaults.store) private var notifyMaster = false
    @AppStorage("limitsProvider", store: SharedDefaults.store) private var limitsProviderRaw =
        LimitProvider.claude.rawValue
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = false
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        false
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = false
    @AppStorage("tabMachinesEnabled", store: SharedDefaults.store) private var machinesEnabled =
        false
    @AppStorage("tabCompanionEnabled", store: SharedDefaults.store) private var companionEnabled =
        false
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var systemStats = false
    @AppStorage("notchShelfEnabled", store: SharedDefaults.store) private var notchShelfEnabled =
        false
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var clipboardEnabled =
        false
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var focusDimEnabled = false
    @AppStorage("micMuteEnabled", store: SharedDefaults.store) private var micMuteEnabled = false
    @AppStorage("colorPickerEnabled", store: SharedDefaults.store) private var colorPickerEnabled =
        false
    @AppStorage("presenterEnabled", store: SharedDefaults.store) private var presenterEnabled =
        false
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @State private var query = ""
    @State private var category = ExtensionMarketplaceCategory.all
    @State private var selectedEntry: ExtensionRegistryEntry?
    @State private var grantedPermissions: [ExtensionPermission: Bool] = [:]
    @State private var permissionRequest: ExtensionPermissionRequest?
    @State private var provisioningEntry: ExtensionRegistryEntry?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            PageHeader(
                "Extensions",
                accessory: {
                    searchField
                    categoryRow
                })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: UIScale.pt(18)) {
                        section("ENABLED", entries: enabledEntries)
                        section("AVAILABLE", entries: availableEntries)
                    }
                    .pageContent(compact)
                    .animation(
                        Motion.animation(Motion.snap, reduceMotion: reduceMotion),
                        value: enabledEntries.map(\.id))
                }
                .scrollIndicators(.never)
                .onAppear {
                    if automaticActionsEnabled { handleDeepLink(using: proxy) }
                }
            }
        }
        .navigationTitle("Extensions")
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: category)
        .onChange(of: systemEnabled) {
            if !systemEnabled { preventSleep = false }
        }
        .onChange(of: grantedPermissions) {
            enableRequestedExtensionIfReady()
        }
        .onAppear {
            guard automaticActionsEnabled else { return }
            refreshPermissionState()
            IPC.post(IPC.Name.requestPermissionsRefresh)
            markEnabledExtensionsSeen()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            if automaticActionsEnabled { refreshPermissionState() }
        }
        .sheet(item: $selectedEntry) { entry in
            ExtensionSettingsSheet(entry: entry)
        }
        .sheet(item: $permissionRequest) { request in
            ExtensionPermissionSheet(
                request: request, grantedPermissions: grantedPermissions,
                grant: { IPC.post($0) }, cancel: { permissionRequest = nil },
                enable: { enableRequestedExtension(request) },
                refresh: requestPermissionRefresh)
        }
        .sheet(item: $provisioningEntry) { entry in
            ToolProvisioningSheet(entry: entry)
        }
    }

    private var searchField: some View {
        SearchField(placeholder: "Search extensions", text: $query, typeAhead: true)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(ExtensionMarketplaceCategory.allCases, id: \.self) { item in
                    Button {
                        withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                            category = item
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                            .foregroundStyle(category == item ? Color.white : Color.secondary)
                            .padding(.horizontal, UIScale.pt(12))
                            .frame(height: UIScale.pt(28))
                            .background(category == item ? Color.accentColor : Color.clear)
                            .clipShape(Capsule())
                            .overlay {
                                if category != item {
                                    Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.65))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var filteredEntries: [ExtensionRegistryEntry] {
        ExtensionMarketplaceFilter.filter(
            entries: ExtensionRegistry.entries, query: query, category: category)
    }

    private var enabledEntries: [ExtensionRegistryEntry] {
        filteredEntries.filter { enabledBinding(for: $0).wrappedValue }
    }

    private var availableEntries: [ExtensionRegistryEntry] {
        filteredEntries.filter { !enabledBinding(for: $0).wrappedValue }
    }

    @ViewBuilder
    private func section(_ title: String, entries: [ExtensionRegistryEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                HStack(spacing: UIScale.pt(6)) {
                    eyebrow(title)
                    Text("\(entries.count)")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                LazyVGrid(columns: gridColumns, spacing: UIScale.pt(14)) {
                    ForEach(entries) { entry in
                        ExtensionMarketplaceCard(
                            entry: entry,
                            enabled: permissionAwareBinding(for: entry),
                            dark: colorScheme == .dark,
                            open: { openSettings(for: entry) }
                        )
                        .id(entry.id)
                    }
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: UIScale.pt(14)),
            GridItem(.flexible(), spacing: UIScale.pt(14)),
        ]
    }

    private func openSettings(for entry: ExtensionRegistryEntry) {
        guard entry.id != "calendar" else { return }
        selectedEntry = entry
    }

    private func handleDeepLink(using proxy: ScrollViewProxy) {
        guard let id = SharedDefaults.store.string(forKey: "extensionsExpand"),
            let entry = ExtensionRegistry.entries.first(where: { $0.id == id })
        else { return }
        SharedDefaults.store.removeObject(forKey: "extensionsExpand")
        query = ""
        category = .all
        DispatchQueue.main.async {
            withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                proxy.scrollTo(entry.id, anchor: .center)
            }
            openSettings(for: entry)
        }
    }

    private var agentUsageBinding: Binding<Bool> {
        Binding(
            get: { usageEnabled },
            set: {
                applyAgentUsageState(AgentUsageSettingsFlow.setEnabled($0, in: agentUsageState))
            }
        )
    }

    private var agentUsageState: AgentUsageSettingsState {
        AgentUsageSettingsState(
            enabled: usageEnabled, claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
            menuBarEnabled: limitsInMenuBar, alertsEnabled: notifyMaster,
            selectedProvider: LimitProvider(rawValue: limitsProviderRaw) ?? .claude)
    }

    private func applyAgentUsageState(_ state: AgentUsageSettingsState) {
        usageEnabled = state.enabled
        claudeEnabled = state.claudeEnabled
        codexEnabled = state.codexEnabled
        limitsInMenuBar = state.menuBarEnabled
        notifyMaster = state.alertsEnabled
    }

    private func enabledBinding(for entry: ExtensionRegistryEntry) -> Binding<Bool> {
        switch entry.defaultsKey {
        case "tabUsageEnabled": agentUsageBinding
        case "tabSystemEnabled": $systemEnabled
        case "tabMachinesEnabled": $machinesEnabled
        case "tabCompanionEnabled": $companionEnabled
        case "menuBarSystemStats": $systemStats
        case "micMuteEnabled": $micMuteEnabled
        case "tabMusicEnabled": $musicEnabled
        case "tabCalendarEnabled": $calendarEnabled
        case "notchShelfEnabled": $notchShelfEnabled
        case "clipboardEnabled": $clipboardEnabled
        case "focusDimEnabled": $focusDimEnabled
        case "presenterEnabled": $presenterEnabled
        case "colorPickerEnabled": $colorPickerEnabled
        default: .constant(false)
        }
    }

    private func permissionAwareBinding(for entry: ExtensionRegistryEntry) -> Binding<Bool> {
        let enabled = enabledBinding(for: entry)
        return Binding(
            get: { enabled.wrappedValue },
            set: { newValue in
                guard newValue else {
                    if enabled.wrappedValue { markPermissionsSeen(for: entry) }
                    enabled.wrappedValue = false
                    return
                }
                let granted = ExtensionPermissionState.readGrantedPermissions()
                grantedPermissions = granted
                let decision = ExtensionPermissionFlow.decision(
                    for: entry, granted: granted,
                    hasSeenPermissions: hasSeenPermissions(for: entry))
                switch decision {
                case .enableDirectly:
                    enabled.wrappedValue = true
                    markPermissionsSeen(for: entry)
                    showProvisioning(for: entry)
                case .showSheet(let required, let optional):
                    enabled.wrappedValue = false
                    permissionRequest = ExtensionPermissionRequest(
                        entry: entry, required: required, optional: optional)
                }
            })
    }

    private static func seenKey(for entry: ExtensionRegistryEntry) -> String {
        "extensionPermissionsSeen.\(entry.id)"
    }

    private func hasSeenPermissions(for entry: ExtensionRegistryEntry) -> Bool {
        SharedDefaults.store.bool(forKey: Self.seenKey(for: entry))
    }

    private func markPermissionsSeen(for entry: ExtensionRegistryEntry) {
        SharedDefaults.store.set(true, forKey: Self.seenKey(for: entry))
    }

    private func markEnabledExtensionsSeen() {
        for entry in ExtensionRegistry.entries
        where SharedDefaults.store.bool(forKey: entry.defaultsKey) {
            markPermissionsSeen(for: entry)
        }
    }

    private func refreshPermissionState() {
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
    }

    private func requestPermissionRefresh() {
        IPC.post(IPC.Name.requestPermissionsRefresh)
        refreshPermissionState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard permissionRequest != nil else { return }
            refreshPermissionState()
        }
    }

    private func enableRequestedExtensionIfReady() {
        guard let request = permissionRequest, !request.required.isEmpty,
            request.entry.requiredPermissions.allSatisfy({ grantedPermissions[$0] == true })
        else { return }
        enableRequestedExtension(request)
    }

    private func enableRequestedExtension(_ request: ExtensionPermissionRequest) {
        enabledBinding(for: request.entry).wrappedValue = true
        markPermissionsSeen(for: request.entry)
        permissionRequest = nil
        DispatchQueue.main.async {
            showProvisioning(for: request.entry)
        }
    }

    private func showProvisioning(for entry: ExtensionRegistryEntry) {
        let tools = entry.requiredTools.filter { $0.requirement.isActive() }
        guard !tools.isEmpty else { return }
        Task {
            for tool in tools { await ToolProvisioner.shared.check(tool).value }
            let hasMissingTool = tools.contains {
                if case .failed = ToolProvisioner.shared.state(for: $0) { return true }
                return false
            }
            if hasMissingTool { provisioningEntry = entry }
        }
    }

}

private struct ExtensionMarketplaceCard: View {
    let entry: ExtensionRegistryEntry
    @Binding var enabled: Bool
    let dark: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            Button(action: open) {
                ExtensionPreview(entry: entry, dark: dark)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScale.pt(52))
                    .background(
                        enabled ? brandAccent.opacity(0.1) : DashSkin.paper(dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            HStack(spacing: UIScale.pt(7)) {
                Button(action: open) {
                    HStack(spacing: UIScale.pt(7)) {
                        Image(systemName: entry.symbolName)
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(enabled ? brandAccent : DashSkin.inkSoft(dark))
                        Text(entry.title)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                if !permissions.isEmpty {
                    PermissionInfoButton(permissions: permissions)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(brandAccent)
                    .pointerCursor()
            }
            Button(action: open) {
                Text(entry.subtitle)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(UIScale.pt(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(14))
                    .fill(DashSkin.paper2(dark))
                Button(action: open) {
                    Color.clear
                        .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(14)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(DashSkin.line(dark), lineWidth: hovering ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.1 : 0), radius: UIScale.pt(8), y: 3)
        .onHover { hovering = $0 }
    }

    private var permissions: [ExtensionPermission] {
        entry.requiredPermissions + entry.optionalPermissions
    }
}

private struct ExtensionSettingsSheet: View {
    let entry: ExtensionRegistryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                RequiredPermissionRows(permissions: entry.requiredPermissions)
                ExtensionDetailRows(entry: entry)
            }
            .formStyle(.grouped)
            .navigationTitle(entry.title)
            .safeAreaInset(edge: .bottom, spacing: UIScale.pt(0)) {
                VStack(spacing: UIScale.pt(0)) {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .pointerCursor()
                    }
                    .padding(.horizontal, UIScale.pt(18))
                    .padding(.vertical, UIScale.pt(12))
                    .background(.bar)
                }
            }
        }
        .frame(
            minWidth: UIScale.pt(520), idealWidth: 560, maxWidth: UIScale.pt(560),
            minHeight: UIScale.pt(260),
            idealHeight: idealHeight, maxHeight: UIScale.pt(620))
    }

    private var idealHeight: CGFloat {
        switch entry.id {
        case "micMute", "systemStats": 300
        case "machines": 420
        case "music": 460
        case "focusDim", "colorPicker": 430
        case "system": 500
        case "notchShelf", "presenter": 580
        default: 620
        }
    }
}

private struct RequiredPermissionRows: View {
    let permissions: [ExtensionPermission]
    @State private var grantedPermissions = ExtensionPermissionState.readGrantedPermissions()

    var body: some View {
        Group {
            if !permissions.isEmpty {
                Section {
                    ForEach(permissions, id: \.self) { permission in
                        HStack(spacing: UIScale.pt(8)) {
                            Image(
                                systemName: grantedPermissions[permission] == true
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(
                                grantedPermissions[permission] == true ? .green : .secondary)
                            Text(permission.displayName)
                            Spacer()
                            if grantedPermissions[permission] != true,
                                let request = permission.grantRequest
                            {
                                Button("Grant...") { IPC.post(request) }
                                    .pointerCursor()
                            }
                        }
                    }
                } header: {
                    Text("Required Access")
                }
            }
        }
        .onAppear {
            IPC.post(IPC.Name.requestPermissionsRefresh)
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        }
    }
}

private struct ExtensionDetailRows: View {
    let entry: ExtensionRegistryEntry

    @ViewBuilder var body: some View {
        switch entry.id {
        case "usage": UsageRows()
        case "system": SystemRows()
        case "machines": MachinesRows()
        case "systemStats": SystemStatsRows()
        case "micMute": MicMuteRows()
        case "music": MusicRows()
        case "notchShelf": NotchShelfRows()
        case "clipboard": ClipboardRows()
        case "focusDim": FocusDimRows()
        case "presenter": PresenterRows()
        case "colorPicker": ColorPickerRows()
        default: EmptyView()
        }
    }
}

private struct ExtensionPermissionRequest: Identifiable {
    let entry: ExtensionRegistryEntry
    let required: [ExtensionPermission]
    let optional: [ExtensionPermission]

    var id: String { entry.id }
}

private struct ExtensionPermissionSheet: View {
    let request: ExtensionPermissionRequest
    let grantedPermissions: [ExtensionPermission: Bool]
    let grant: (Notification.Name) -> Void
    let cancel: () -> Void
    let enable: () -> Void
    let refresh: () -> Void

    private var requiredGranted: Bool {
        request.entry.requiredPermissions.allSatisfy { grantedPermissions[$0] == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HStack(spacing: UIScale.pt(14)) {
                Image(systemName: request.entry.symbolName)
                    .font(.system(size: UIScale.pt(22), weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: UIScale.pt(44), height: UIScale.pt(44))
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Enable \(request.entry.title)")
                        .font(.system(size: UIScale.pt(17), weight: .semibold))
                    Text(request.entry.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            VStack(spacing: UIScale.pt(10)) {
                ForEach(request.required, id: \.self) { permission in
                    permissionCard(permission, required: true)
                }
                ForEach(request.optional, id: \.self) { permission in
                    permissionCard(permission, required: false)
                }
            }
            HStack(spacing: UIScale.pt(10)) {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                if request.required.isEmpty {
                    Button("Enable anyway", action: enable)
                        .keyboardShortcut(.defaultAction)
                        .pointerCursor()
                } else {
                    Button("Enable when granted", action: enable)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!requiredGranted)
                        .pointerCursor()
                }
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(540))
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
    }

    private func permissionCard(_ permission: ExtensionPermission, required: Bool) -> some View {
        let isGranted = grantedPermissions[permission] == true
        return HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: permission.symbolName)
                .font(.system(size: UIScale.pt(16), weight: .medium))
                .foregroundStyle(isGranted ? .green : .secondary)
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                .background(
                    (isGranted ? Color.green : Color.secondary).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(permission.displayName)
                        .fontWeight(.medium)
                    PermissionInfoButton(permission)
                    Text(required ? "Required" : "Optional")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(required ? .orange : .secondary)
                }
                Text(permission.reason)
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
                if let firstUseExplanation = permission.firstUseExplanation {
                    Text(firstUseExplanation)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(.green)
            } else if let request = permission.grantRequest {
                Button("Grant") { grant(request) }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(UIScale.pt(14))
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12), style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        }
    }
}

private struct UsageRows: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true
    @AppStorage("claudeLimitsEnabled", store: SharedDefaults.store) private var claudeEnabled = true
    @AppStorage("codexLimitsEnabled", store: SharedDefaults.store) private var codexEnabled = true
    @AppStorage("limitsProvider", store: SharedDefaults.store) private var limitsProviderRaw =
        LimitProvider.claude.rawValue
    @AppStorage("menuBarColorMode", store: SharedDefaults.store) private var menuBarColorMode =
        "auto"
    @AppStorage("smartColor", store: SharedDefaults.store) private var smartColor = true
    @AppStorage("menuBarSubColorHex", store: SharedDefaults.store) private var subColorHex =
        "8E8E93"
    @AppStorage("menuBarLowColorHex", store: SharedDefaults.store) private var lowColorHex =
        "34C759"
    @AppStorage("menuBarMidColorHex", store: SharedDefaults.store) private var midColorHex =
        "FF9500"
    @AppStorage("menuBarHighColorHex", store: SharedDefaults.store) private var highColorHex =
        "FF3B30"
    @AppStorage("warnPercent", store: SharedDefaults.store) private var warnPercent = 60
    @AppStorage("critPercent", store: SharedDefaults.store) private var critPercent = 85
    @AppStorage("pacingMargin", store: SharedDefaults.store) private var pacingMargin = 10.0
    @AppStorage("budgetEnabled", store: SharedDefaults.store) private var budgetEnabled = false
    @AppStorage("budgetMode", store: SharedDefaults.store) private var budgetMode = "pace"
    @AppStorage("budgetKind", store: SharedDefaults.store) private var budgetKind = "weekly"
    @AppStorage("budgetCapPercent", store: SharedDefaults.store) private var budgetCap = 50.0
    @AppStorage("budgetDeadline", store: SharedDefaults.store) private var budgetDeadlineTS = 0.0
    @AppStorage("notifyMaster", store: SharedDefaults.store) private var notifyMaster = false
    @AppStorage("notifyTrackSession", store: SharedDefaults.store) private var trackSession = true
    @AppStorage("notifyTrackWeekly", store: SharedDefaults.store) private var trackWeekly = true
    @AppStorage("notifyRecovery", store: SharedDefaults.store) private var recovery = true
    @AppStorage("notifyPacingWarning", store: SharedDefaults.store) private var pacingWarning = true
    @AppStorage("notifyPacingHot", store: SharedDefaults.store) private var pacingHot = true
    @AppStorage("notifyReminderSession", store: SharedDefaults.store) private var reminderSession =
        false
    @AppStorage("notifyReminderSessionOffsetMin", store: SharedDefaults.store)
    private var reminderSessionOffset = 30
    @AppStorage("notifyReminderWeekly", store: SharedDefaults.store) private var reminderWeekly =
        false
    @AppStorage("notifyReminderWeeklyOffsetMin", store: SharedDefaults.store)
    private var reminderWeeklyOffset = 120
    @AppStorage("notifyTokenExpired", store: SharedDefaults.store) private var tokenExpired = true
    @State private var testSent = false

    private var hasProvider: Bool { claudeEnabled || codexEnabled }

    var body: some View {
        CLIToolStatusSection(
            tools: ExtensionRegistry.entries.first { $0.id == "usage" }?.requiredTools ?? [],
            extensionEnabled: enabled)

        UsageMachineRows(extensionEnabled: enabled)

        Section {
            Group {
                Toggle("Claude limits", isOn: $claudeEnabled)
                    .pointerCursor()
                Toggle("Codex limits", isOn: $codexEnabled)
                    .pointerCursor()
                Toggle("Show limits in the menu bar", isOn: $limitsInMenuBar)
                    .pointerCursor()

                if limitsInMenuBar {
                    Picker("Color", selection: colorModeBinding) {
                        Text("White").tag("white")
                        Text("Black").tag("black")
                        Text("Custom").tag("custom")
                    }
                    .pointerCursor()

                    if isCustomColor {
                        ColorPicker(
                            "Text (5h / 7d)", selection: hexBinding($subColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "Low risk", selection: hexBinding($lowColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "Medium risk", selection: hexBinding($midColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "High risk", selection: hexBinding($highColorHex),
                            supportsOpacity: false)
                        Toggle("Smart color", isOn: $smartColor)
                            .pointerCursor()
                        if !smartColor {
                            HStack {
                                Text("Thresholds")
                                Spacer()
                                Stepper(
                                    "Warn \(warnPercent)%", value: $warnPercent,
                                    in: 10...critPercent - 5, step: 5
                                )
                                .pointerCursor()
                                Stepper(
                                    "Critical \(critPercent)%", value: $critPercent,
                                    in: warnPercent + 5...100, step: 5
                                )
                                .pointerCursor()
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
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
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
            Toggle("Pace my Claude usage", isOn: $budgetEnabled)
                .pointerCursor()
            Text(
                "Set a personal cap under the real limit and get told if you're spending too fast."
            )
            .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
            if budgetEnabled {
                Picker("Mode", selection: $budgetMode) {
                    Text("Auto daily pace").tag("pace")
                    Text("Cap by a deadline").tag("cap")
                }.pointerCursor()
                Picker("Window", selection: $budgetKind) {
                    Text("Weekly").tag("weekly")
                    Text("Session (5h)").tag("session")
                }.pointerCursor()
                HStack {
                    Text("Cap")
                    Slider(value: $budgetCap, in: 10...100, step: 5)
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
                            set: { budgetDeadlineTS = $0.timeIntervalSinceReferenceDate }),
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
                .pointerCursor()
            Group {
                Toggle(isOn: $trackSession) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Session (5h) alerts")
                        InfoDot(
                            "Fires once when the session window crosses warn or critical - it won't repeat while you stay in that zone."
                        )
                    }
                }
                .pointerCursor()
                Toggle(isOn: $trackWeekly) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Weekly alerts")
                        InfoDot(
                            "Fires once when the weekly window crosses warn or critical - same one-shot-per-zone behavior as session alerts."
                        )
                    }
                }
                .pointerCursor()
                Toggle("Back to green", isOn: $recovery)
                    .pointerCursor()
                HStack {
                    Text("Pacing margin")
                    Spacer()
                    Stepper(
                        "±\(Int(pacingMargin)) pp", value: $pacingMargin, in: 5...25, step: 5
                    )
                    .pointerCursor()
                }
                Toggle(isOn: $pacingWarning) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Drifting / burning hot")
                        InfoDot(
                            "A separate signal from the level alerts above: how far ahead of an even burn-rate pace you are, regardless of the absolute percentage."
                        )
                    }
                }
                .pointerCursor()
                Toggle("Token expired", isOn: $tokenExpired)
                    .pointerCursor()
                HStack {
                    Toggle("Remind before session reset", isOn: $reminderSession)
                        .pointerCursor()
                    Picker("", selection: $reminderSessionOffset) {
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 h").tag(60)
                    }
                    .labelsHidden().pointerCursor().disabled(!reminderSession)
                }
                HStack {
                    Toggle("Remind before weekly reset", isOn: $reminderWeekly)
                        .pointerCursor()
                    Picker("", selection: $reminderWeeklyOffset) {
                        Text("1 h").tag(60)
                        Text("2 h").tag(120)
                        Text("6 h").tag(360)
                        Text("12 h").tag(720)
                    }
                    .labelsHidden().pointerCursor().disabled(!reminderWeekly)
                }
            }
            .disabled(!notifyMaster)
            .opacity(notifyMaster ? 1 : 0.5)

            HStack {
                Button("Send test notification") {
                    IPC.post(IPC.Name.requestTestNotification)
                    testSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testSent = false }
                }
                .pointerCursor()
                if testSent {
                    Text("Sent - check Notification Center")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text(
                "Alerts fire once per level or zone crossing, not on a repeating timer - staying in the same zone won't page you again."
            )
            .font(.system(size: UIScale.pt(10)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onChange(of: claudeEnabled) { reconcileProviders() }
        .onChange(of: codexEnabled) {
            if enabled && codexEnabled { ToolProvisioner.shared.provision(.codex) }
            reconcileProviders()
        }
    }

    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { notifyMaster },
            set: { enabled in
                notifyMaster = enabled
                if enabled && !SharedDefaults.store.bool(forKey: "permNotificationsGranted") {
                    IPC.post(IPC.Name.grantNotifications)
                }
            })
    }

    private var isCustomColor: Bool {
        menuBarColorMode == "custom" || menuBarColorMode == "auto"
    }

    private var colorModeBinding: Binding<String> {
        Binding(
            get: { isCustomColor ? "custom" : menuBarColorMode },
            set: { menuBarColorMode = $0 })
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
        let state = AgentUsageSettingsFlow.providersChanged(
            AgentUsageSettingsState(
                enabled: enabled, claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
                menuBarEnabled: limitsInMenuBar, alertsEnabled: notifyMaster,
                selectedProvider: selectedProvider))
        enabled = state.enabled
        limitsInMenuBar = state.menuBarEnabled
        notifyMaster = state.alertsEnabled
    }
}

private struct SystemStatsRows: View {
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var enabled = false
    @AppStorage("menuBarStatsColorHex", store: SharedDefaults.store) private var statsColorHex =
        "FFFFFF"

    var body: some View {
        Section {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { DashPalette.color(statsColorHex) },
                    set: { statsColorHex = $0.hex6 }),
                supportsOpacity: false)
            Text("Sampled every couple of seconds; costs nothing measurable.")
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct MusicRows: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage(MusicFade.enabledKey, store: SharedDefaults.store) private var crossfade = true
    @AppStorage(MusicFade.secondsKey, store: SharedDefaults.store) private var crossfadeSeconds =
        MusicFade.defaultSeconds

    var body: some View {
        CLIToolStatusSection(tools: [.youtubeDownloader], extensionEnabled: enabled)

        Section {
            LabeledContent("Music folder") {
                Button("Open in Finder") {
                    try? FileManager.default.createDirectory(
                        at: Repo.musicDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Repo.musicDir)
                }
                .pointerCursor()
            }
            Toggle("Fade between tracks", isOn: $crossfade)
                .pointerCursor()
            if crossfade {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Fade length") {
                        Text(String(format: "%.1fs", crossfadeSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $crossfadeSeconds, in: MusicFade.secondsRange)
                        .pointerCursor()
                    Text("How long the old track fades out while the next one fades in.")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct MicMuteRows: View {
    @AppStorage("micMuteEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("micMuteInMenuBar", store: SharedDefaults.store) private var inMenuBar = true

    var body: some View {
        Section {
            Toggle("Show in the menu bar", isOn: $inMenuBar)
                .pointerCursor()
            Text("The menu bar icon shows the current mute state and toggles it on click.")
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SystemRows: View {
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var enabled = false
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @State private var cleaningStarted = false

    var body: some View {
        Section {
            Toggle(isOn: $preventSleep) {
                HStack(spacing: UIScale.pt(6)) {
                    Text("Keep awake")
                    InfoDot(
                        "Keeps your Mac awake until you turn this off again, even with the lid closed on power."
                    )
                }
            }
            .pointerCursor()
            HStack {
                Text("Keyboard cleaning")
                InfoDot(
                    "Locks the keyboard so you can wipe it without typing anything. Press the on-screen button or wait for the timer to unlock."
                )
                Spacer()
                if cleaningStarted {
                    Text("Locked - check the overlay")
                        .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                }
                Button("Clean now") {
                    IPC.post(IPC.Name.requestKeyboardClean)
                    cleaningStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        cleaningStarted = false
                    }
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
