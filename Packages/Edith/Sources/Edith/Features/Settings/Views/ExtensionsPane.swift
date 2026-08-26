import AppKit
import Combine
import EdithKit
import SwiftUI

@MainActor enum ExtensionPermissionState {
    static func readGrantedPermissions() -> [ExtensionPermission: Bool] {
        MainPermissionOperations.center.grantedPermissions()
    }
}

@propertyWrapper
struct ExtensionEnablementStorage: DynamicProperty {
    private let defaultsKey: String
    private let store: UserDefaults
    @AppStorage private var storedValue: Bool

    init(defaultsKey: String, store: UserDefaults = SharedDefaults.store) {
        self.defaultsKey = defaultsKey
        self.store = store
        _storedValue = AppStorage(wrappedValue: false, defaultsKey, store: store)
    }

    init(entry: ExtensionRegistryEntry, store: UserDefaults = SharedDefaults.store) {
        self.init(defaultsKey: entry.defaultsKey, store: store)
    }

    var wrappedValue: Bool {
        get {
            let observedValue = storedValue
            return store.object(forKey: defaultsKey) as? Bool ?? observedValue
        }
        nonmutating set { storedValue = newValue }
    }

    var projectedValue: Binding<Bool> {
        $storedValue
    }
}

struct ExtensionsPane: View {
    @State private var query = ""
    @State private var category = ExtensionMarketplaceCategory.all
    @State private var selectedEntry: ExtensionRegistryEntry?
    @State private var grantedPermissions: [ExtensionPermission: Bool] = [:]
    @State private var permissionRequest: ExtensionPermissionRequest?
    @State private var provisioningEntry: ExtensionRegistryEntry?
    @StateObject private var lidAwakeOperations = LidAwakeOperationModel()
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
                    extensionGrid
                        .pageContent(compact)
                }
                .scrollIndicators(.never)
                .onAppear {
                    if automaticActionsEnabled { handleDeepLink(using: proxy) }
                }
            }
        }
        .navigationTitle("Extensions")
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: category)
        .onChange(of: grantedPermissions) {
            enableRequestedExtensionIfReady()
        }
        .onAppear {
            guard automaticActionsEnabled else { return }
            refreshPermissionState()
            _ = MainPermissionOperations.center.refresh()
            markEnabledExtensionsSeen()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            if automaticActionsEnabled { refreshPermissionState() }
        }
        .sheet(item: $selectedEntry) { entry in
            ExtensionSettingsSheet(entry: entry, lidAwakeOperations: lidAwakeOperations)
        }
        .sheet(item: $permissionRequest) { request in
            ExtensionPermissionSheet(
                request: request, grantedPermissions: grantedPermissions,
                grant: { _ = try MainPermissionOperations.center.request($0) },
                openSettings: { _ = try MainPermissionOperations.center.openSettings(for: $0) },
                cancel: { permissionRequest = nil },
                enable: { enableRequestedExtension(request) },
                refresh: requestPermissionRefresh)
        }
        .sheet(item: $provisioningEntry) { entry in
            ToolProvisioningSheet(entry: entry)
        }
        .alert(
            "Lid Awake could not change state",
            isPresented: Binding(
                get: { selectedEntry == nil && lidAwakeErrorMessage != nil },
                set: { if !$0 { lidAwakeOperations.clearError() } })
        ) {
            Button("OK") { lidAwakeOperations.clearError() }
        } message: {
            Text(lidAwakeErrorMessage ?? "")
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
            entries: inspectionCenter.list().map(\.entry), query: query, category: category)
    }

    @ViewBuilder
    private var extensionGrid: some View {
        if filteredEntries.isEmpty {
            let state = ExtensionMarketplaceFilter.emptyState(query: query, category: category)
            ContentUnavailableView {
                Label(state.title, systemImage: "magnifyingglass")
            } description: {
                Text(state.detail)
            }
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
        } else {
            LazyVGrid(columns: gridColumns, spacing: UIScale.pt(14)) {
                ForEach(filteredEntries) { entry in
                    ExtensionMarketplaceCard(
                        entry: entry,
                        dark: colorScheme == .dark,
                        switchDisabled: entry.defaultsKey == LidAwakeState.enabledKey
                            && lidAwakeOperations.applying,
                        open: { openSettings(for: entry) },
                        setEnabled: { setEnabled($0, for: entry) }
                    )
                    .id(entry.id)
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
        selectedEntry = inspectionCenter.info(entry).entry
    }

    private var inspectionCenter: ExtensionInspectionCenter {
        ExtensionInspectionCenter(environment: ExtensionMutationCenter.application.environment)
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

    private func setEnabled(_ newValue: Bool, for entry: ExtensionRegistryEntry) {
        if entry.defaultsKey == LidAwakeState.enabledKey, !newValue {
            lidAwakeOperations.perform(.disableExtension)
            return
        }
        let coordinator = ExtensionModalCoordinator(
            entry: entry, mutationCenter: .application)
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        switch coordinator.setEnabled(newValue) {
        case let .applied(_, missingRequiredTools):
            if !missingRequiredTools.isEmpty { provisioningEntry = entry }
        case let .needsPermissions(plan):
            permissionRequest = ExtensionPermissionRequest(
                entry: entry, required: plan.required, optional: plan.optional)
        }
    }

    private func markEnabledExtensionsSeen() {
        let center = ExtensionMutationCenter.application
        for entry in ExtensionRegistry.entries
        where SharedDefaults.store.bool(forKey: entry.defaultsKey) {
            center.markPermissionsSeen(for: entry)
        }
    }

    private func refreshPermissionState() {
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
    }

    private func requestPermissionRefresh() {
        _ = MainPermissionOperations.center.refresh()
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
        let coordinator = ExtensionModalCoordinator(
            entry: request.entry, mutationCenter: .application)
        let outcome = coordinator.enableAfterPermissions()
        permissionRequest = nil
        guard case let .applied(_, missingRequiredTools) = outcome,
            !missingRequiredTools.isEmpty
        else { return }
        DispatchQueue.main.async { provisioningEntry = request.entry }
    }

    private var lidAwakeErrorMessage: String? {
        lidAwakeOperations.errorMessage ?? lidAwakeOperations.lastSnapshot?.lastError
    }

}

private struct ExtensionMarketplaceCard: View {
    let entry: ExtensionRegistryEntry
    @ExtensionEnablementStorage private var enabled: Bool
    let dark: Bool
    let switchDisabled: Bool
    let open: () -> Void
    let setEnabled: (Bool) -> Void
    @State private var hovering = false

    init(
        entry: ExtensionRegistryEntry, dark: Bool, switchDisabled: Bool = false,
        open: @escaping () -> Void,
        setEnabled: @escaping (Bool) -> Void
    ) {
        self.entry = entry
        self.dark = dark
        self.switchDisabled = switchDisabled
        self.open = open
        self.setEnabled = setEnabled
        _enabled = ExtensionEnablementStorage(entry: entry)
    }

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
                        AppGlyph(entry, size: UIScale.pt(13), weight: .semibold)
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
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(brandAccent)
                    .disabled(switchDisabled)
                    .pointerCursor()
            }
            Button(action: open) {
                Text(entry.lifecycle?.value ?? entry.subtitle)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(2)
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

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: setEnabled)
    }
}

struct ExtensionSettingsHeader: View {
    let title: String
    @Binding var enabled: Bool
    let disabled: Bool

    init(title: String, enabled: Binding<Bool>, disabled: Bool = false) {
        self.title = title
        _enabled = enabled
        self.disabled = disabled
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Toggle(isOn: $enabled) {
                Text("\(title) enabled")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(disabled)
            .accessibilityLabel("\(title) enabled")
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(28))
        .padding(.vertical, UIScale.pt(18))
    }
}

private struct ExtensionSettingsSheet: View {
    let entry: ExtensionRegistryEntry
    let coordinator: ExtensionModalCoordinator
    @Environment(\.dismiss) private var dismiss
    @ExtensionEnablementStorage private var enabled: Bool
    @State private var grantedPermissions: [ExtensionPermission: Bool]
    @State private var permissionRequest: ExtensionPermissionRequest?
    @State private var provisioningEntry: ExtensionRegistryEntry?
    @State private var invalidation = 0
    @ObservedObject private var lidAwakeOperations: LidAwakeOperationModel

    init(entry: ExtensionRegistryEntry, lidAwakeOperations: LidAwakeOperationModel) {
        let coordinator = ExtensionModalCoordinator(
            entry: entry, mutationCenter: .application)
        self.entry = entry
        self.coordinator = coordinator
        _lidAwakeOperations = ObservedObject(wrappedValue: lidAwakeOperations)
        _enabled = ExtensionEnablementStorage(entry: entry)
        _grantedPermissions = State(
            initialValue: ExtensionPermissionState.readGrantedPermissions())
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            ExtensionSettingsHeader(
                title: entry.title, enabled: enabledBinding,
                disabled: entry.defaultsKey == LidAwakeState.enabledKey
                    && lidAwakeOperations.applying)

            Divider()

            Form {
                ExtensionDetailRows(entry: entry)
                if enabled, !coordinator.missingRequiredTools.isEmpty {
                    Section {
                        Button("Set up required tools...") {
                            provisioningEntry = entry
                        }
                        .pointerCursor()
                    }
                }
                ExtensionLifecycleRows(
                    entry: entry, coordinator: coordinator, invalidation: invalidation)
                ExtensionPermissionRows(entry: entry) {
                    invalidateReadiness()
                }
            }
            .formStyle(.grouped)
        }
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
        .onChange(of: grantedPermissions) {
            enableAfterPermissionGrantIfReady()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
            invalidateReadiness()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.settingsChanged)
        ) { _ in
            enabled = coordinator.isEnabled
            invalidateReadiness()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cliToolProvisioned)) { _ in
            invalidateReadiness()
        }
        .sheet(item: $permissionRequest) { request in
            ExtensionPermissionSheet(
                request: request, grantedPermissions: grantedPermissions,
                grant: { _ = try MainPermissionOperations.center.request($0) },
                openSettings: { _ = try MainPermissionOperations.center.openSettings(for: $0) },
                cancel: { permissionRequest = nil },
                enable: { enableAfterPermissions() },
                refresh: refreshPermissionState)
        }
        .sheet(item: $provisioningEntry) { entry in
            ToolProvisioningSheet(entry: entry) {
                invalidateReadiness()
            }
        }
        .alert(
            "Lid Awake could not change state",
            isPresented: Binding(
                get: { lidAwakeErrorMessage != nil },
                set: { if !$0 { lidAwakeOperations.clearError() } })
        ) {
            Button("OK") { lidAwakeOperations.clearError() }
        } message: {
            Text(lidAwakeErrorMessage ?? "")
        }
        .frame(
            minWidth: UIScale.pt(520), idealWidth: 560, maxWidth: UIScale.pt(560),
            minHeight: UIScale.pt(260),
            idealHeight: idealHeight, maxHeight: UIScale.pt(620))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { wanted in
                if entry.defaultsKey == LidAwakeState.enabledKey, !wanted {
                    disableLidAwake()
                    return
                }
                grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
                switch coordinator.setEnabled(wanted) {
                case let .applied(result, missingRequiredTools):
                    enabled = result.enabled
                    invalidateReadiness()
                    if !missingRequiredTools.isEmpty { provisioningEntry = entry }
                case let .needsPermissions(plan):
                    permissionRequest = ExtensionPermissionRequest(
                        entry: entry, required: plan.required, optional: plan.optional)
                }
            })
    }

    private func disableLidAwake() {
        guard let task = lidAwakeOperations.perform(.disableExtension) else { return }
        Task { @MainActor in
            await task.value
            enabled = coordinator.isEnabled
            invalidateReadiness()
        }
    }

    private var lidAwakeErrorMessage: String? {
        lidAwakeOperations.errorMessage ?? lidAwakeOperations.lastSnapshot?.lastError
    }

    private func refreshPermissionState() {
        _ = MainPermissionOperations.center.refresh()
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        invalidateReadiness()
    }

    private func enableAfterPermissionGrantIfReady() {
        guard let request = permissionRequest, !request.required.isEmpty,
            request.required.allSatisfy({ grantedPermissions[$0] == true })
        else { return }
        enableAfterPermissions()
    }

    private func enableAfterPermissions() {
        guard
            case let .applied(result, missingRequiredTools) =
                coordinator.enableAfterPermissions()
        else { return }
        enabled = result.enabled
        permissionRequest = nil
        invalidateReadiness()
        guard !missingRequiredTools.isEmpty else { return }
        DispatchQueue.main.async { provisioningEntry = entry }
    }

    private func invalidateReadiness() {
        invalidation &+= 1
    }

    private var idealHeight: CGFloat {
        switch entry.id {
        case "micMute", "systemStats": 300
        case "attention": 440
        case "machines": 420
        case "lidAwake": 400
        case "music": 460
        case "focusDim", "colorPicker": 430
        case "system": 500
        case "notchShelf", "presenter": 580
        default: 620
        }
    }
}

private struct ExtensionLifecycleRows: View {
    let entry: ExtensionRegistryEntry
    let coordinator: ExtensionModalCoordinator
    let invalidation: Int
    @State private var readiness: ExtensionReadinessModel

    init(
        entry: ExtensionRegistryEntry, coordinator: ExtensionModalCoordinator,
        invalidation: Int
    ) {
        self.entry = entry
        self.coordinator = coordinator
        self.invalidation = invalidation
        _readiness = State(
            initialValue: ExtensionReadinessModel {
                await coordinator.lifecycleReport($0)
            })
    }

    var body: some View {
        Group {
            Section("Readiness") {
                if let report = readiness.report {
                    if report.state.phase != .enabled, report.state.phase != .disabled {
                        LabeledContent("State") {
                            Label(
                                report.state.phase.title,
                                systemImage: phaseSymbol(report.state.phase)
                            )
                            .foregroundStyle(phaseColor(report.state.phase))
                        }
                    }
                    LabeledContent("Runtime") {
                        Label(
                            report.state.runtimePhase.title,
                            systemImage: runtimeSymbol(report.state.runtimePhase)
                        )
                        .foregroundStyle(runtimeColor(report.state.runtimePhase))
                    }
                    if report.state.phase != .enabled, report.state.phase != .disabled {
                        Text(report.state.summary)
                            .settingsCaption()
                    }
                    ForEach(report.checks) { check in
                        checkRow(check)
                    }
                    Button("Check again") {
                        readiness.refresh(.verify)
                    }
                    .pointerCursor()
                } else {
                    let loading = ExtensionLifecycleState.loading(extensionID: entry.id)
                    HStack(spacing: UIScale.pt(8)) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(loading.runtimePhase.title) readiness...")
                            .settingsCaption()
                    }
                }
            }
            if let lifecycle = entry.lifecycle {
                Section("About") {
                    Text(lifecycle.value)
                    ForEach(lifecycle.workflows) { workflow in
                        instructionRow(workflow)
                    }
                }
                Section("Setup") {
                    ForEach(lifecycle.prerequisites) { prerequisite in
                        instructionRow(prerequisite)
                    }
                }
                Section("Command line") {
                    ForEach(lifecycle.cliExamples, id: \.self) { example in
                        Text(example)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section("Verify and recover") {
                    ForEach(lifecycle.verification) { verification in
                        instructionRow(verification)
                    }
                    ForEach(lifecycle.recovery) { recovery in
                        instructionRow(recovery)
                    }
                    ForEach(lifecycle.documentation) { document in
                        Button(document.title) {
                            _ = try? AppInspectionCenter().openLink(
                                AppInspectionCenter.extensionDocumentationID(
                                    extensionID: entry.id, documentID: document.id),
                                contributors: [])
                        }
                        .buttonStyle(.link)
                    }
                }
            } else {
                Section("About") {
                    Text(entry.subtitle)
                }
            }
        }
        .task(id: "\(entry.id):\(invalidation)") {
            let discoveryTrace = PerformanceTrace.begin(.extensionDiscovery, "extensions.report")
            defer { PerformanceTrace.end(discoveryTrace) }
            await readiness.refresh(.status).value
        }
        .onDisappear { readiness.cancel() }
    }

    private func checkRow(_ check: ExtensionLifecycleCheck) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: checkSymbol(check.status))
                    .foregroundStyle(checkColor(check.status))
                Text(check.title)
                    .fontWeight(.medium)
                Spacer()
                Text(checkTitle(check.status))
                    .settingsCaption()
            }
            Text(check.detail)
                .settingsCaption()
            if let command = check.recoveryCommand {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func phaseSymbol(_ phase: ExtensionLifecyclePhase) -> String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .failed, .unavailable: "xmark.circle.fill"
        case .checking: "arrow.clockwise.circle"
        case .disabled, .enabled, .needsSetup: "circle.dashed"
        }
    }

    private func phaseColor(_ phase: ExtensionLifecyclePhase) -> Color {
        switch phase {
        case .ready: .green
        case .degraded: .orange
        case .failed, .unavailable: .red
        case .checking, .disabled, .enabled, .needsSetup: .secondary
        }
    }

    private func runtimeSymbol(_ phase: ExtensionRuntimePhase) -> String {
        switch phase {
        case .installed: "checkmark.circle.fill"
        case .uninstalled: "arrow.down.circle"
        case .empty: "tray"
        case .loading: "arrow.clockwise.circle"
        case .unsupported: "nosign"
        case .error: "xmark.circle.fill"
        }
    }

    private func runtimeColor(_ phase: ExtensionRuntimePhase) -> Color {
        switch phase {
        case .installed: .green
        case .empty: .orange
        case .error, .unsupported: .red
        case .loading, .uninstalled: .secondary
        }
    }

    private func checkSymbol(_ status: ExtensionLifecycleCheckStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func checkColor(_ status: ExtensionLifecycleCheckStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .skipped: .secondary
        }
    }

    private func checkTitle(_ status: ExtensionLifecycleCheckStatus) -> String {
        switch status {
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    private func instructionRow(_ instruction: ExtensionLifecycleInstruction) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(instruction.title)
                .fontWeight(.medium)
            Text(instruction.detail)
                .settingsCaption()
            if let command = instruction.command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ExtensionPermissionRows: View {
    let entry: ExtensionRegistryEntry
    let changed: () -> Void
    @State private var grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
    @State private var actionError: String?

    private var permissions: [(permission: ExtensionPermission, required: Bool)] {
        entry.requiredPermissions.map { ($0, true) }
            + entry.optionalPermissions.map { ($0, false) }
    }

    var body: some View {
        Group {
            if !permissions.isEmpty {
                Section {
                    ForEach(permissions, id: \.permission) { item in
                        let permission = item.permission
                        HStack(spacing: UIScale.pt(8)) {
                            Image(
                                systemName: grantedPermissions[permission] == true
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(
                                grantedPermissions[permission] == true ? .green : .secondary)
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                HStack(spacing: UIScale.pt(6)) {
                                    Text(permission.displayName)
                                    Text(item.required ? "Required" : "Optional")
                                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                                        .foregroundStyle(item.required ? .orange : .secondary)
                                }
                                Text(permission.reason)
                                    .settingsCaption()
                            }
                            Spacer()
                            if grantedPermissions[permission] == true {
                                Text("Granted")
                                    .settingsCaption()
                                    .foregroundStyle(.green)
                            } else {
                                permissionAction(permission)
                            }
                        }
                    }
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .settingsCaption()
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text("Required access blocks setup. Optional access unlocks extra features.")
                }
            }
        }
        .onAppear {
            _ = MainPermissionOperations.center.refresh()
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
            changed()
        }
    }

    @ViewBuilder private func permissionAction(_ permission: ExtensionPermission) -> some View {
        let remediation = MainPermissionOperations.center.remediation(for: permission)
        switch remediation.action {
        case .request:
            Button("Grant...") { request(permission) }
                .pointerCursor()
        case .firstUse:
            if remediation.settingsURL != nil {
                Button("Open Settings...") { openSettings(permission) }
                    .pointerCursor()
            } else {
                Text("On first use")
                    .settingsCaption()
            }
        case .none:
            EmptyView()
        }
    }

    private func request(_ permission: ExtensionPermission) {
        do {
            _ = try MainPermissionOperations.center.request(permission)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func openSettings(_ permission: ExtensionPermission) {
        do {
            _ = try MainPermissionOperations.center.openSettings(for: permission)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func refresh() {
        _ = MainPermissionOperations.center.refresh()
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        changed()
    }
}

private struct ExtensionDetailRows: View {
    let entry: ExtensionRegistryEntry

    @ViewBuilder var body: some View {
        if let route = ExtensionDetailRoute(rawValue: entry.id) {
            switch route {
            case .attention: AttentionRows()
            case .usage: UsageRows()
            case .herdr: HerdrRows()
            case .quinjet: QuinjetRows()
            case .system: SystemRows()
            case .machines: MachinesRows()
            case .companion: CompanionRows()
            case .systemStats: SystemStatsRows()
            case .micMute: MicMuteRows()
            case .lidAwake: LidAwakeRows()
            case .music: MusicRows()
            case .calendar: CalendarRows()
            case .notchShelf: NotchShelfRows()
            case .clipboard: ClipboardRows()
            case .focusDim: FocusDimRows()
            case .presenter: PresenterRows()
            case .colorPicker: ColorPickerRows()
            }
        } else {
            Section("Controls") {
                Text("No extension controls are registered for \(entry.title).")
                    .settingsCaption()
            }
        }
    }
}

private struct AttentionRows: View {
    @AppStorage(AppStorageKeys.Tabs.attentionEnabled, store: SharedDefaults.store) private
        var enabled = false
    @State private var model = AttentionPageModel()

    var body: some View {
        Section("Tracking") {
            Toggle("Track foreground applications", isOn: $model.settings.trackingEnabled)
            Toggle("Run local browser server", isOn: $model.settings.browserTrackingEnabled)
            HStack {
                Button("Save tracking settings") {
                    model.settings.isEnabled =
                        model.settings.trackingEnabled || model.settings.browserTrackingEnabled
                    model.saveSettings()
                }
                .pointerCursor()
                Button("Open Attention") { SectionWindow.open(.attention) }
                    .pointerCursor()
            }
            if let message = model.message {
                Text(message)
                    .settingsCaption()
                    .foregroundStyle(.green)
            }
            if let error = model.errorMessage {
                Text(error)
                    .settingsCaption()
                    .foregroundStyle(.red)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .task { model.reload() }
    }
}

private struct HerdrRows: View {
    @AppStorage(AppStorageKeys.Tabs.herdrEnabled, store: SharedDefaults.store) private var enabled =
        false
    @State private var checkTask: Task<Void, Never>?
    @State private var checkResult: String?
    @State private var checkFailed = false
    @State private var checking = false
    @State private var actionError: String?

    var body: some View {
        Section("Sessions") {
            LabeledContent("Sources", value: "This Mac and SSH machines")
            Text("Follow live agent sessions, inspect their state, and open workspace diffs.")
                .settingsCaption()
            HStack {
                Button("Check sessions") { checkSessions() }
                    .disabled(checking)
                    .pointerCursor()
                Button("Open Herdr") { SectionWindow.open(.herdr) }
                    .pointerCursor()
                Button("Open setup guide") { openGuide() }
                    .pointerCursor()
            }
            if checking {
                ProgressView()
                    .controlSize(.small)
            } else if let checkResult {
                Text(checkResult)
                    .settingsCaption()
                    .foregroundStyle(checkFailed ? .red : .green)
            }
            if let actionError {
                Text(actionError)
                    .settingsCaption()
                    .foregroundStyle(.red)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onDisappear { checkTask?.cancel() }
    }

    private func checkSessions() {
        checkTask?.cancel()
        checking = true
        checkResult = nil
        checkTask = Task {
            let hosts = await HerdrSessionOperationExecution.list()
            guard !Task.isCancelled else { return }
            let installed = hosts.filter(\.herdrPresent)
            let agents = installed.flatMap(\.agents)
            if installed.isEmpty {
                checkResult = "Herdr was not found on this Mac or a configured machine."
                checkFailed = true
            } else if agents.isEmpty {
                checkResult = "Herdr is installed, but no live sessions were found."
                checkFailed = false
            } else {
                checkResult = "Found \(agents.count) live Herdr sessions."
                checkFailed = false
            }
            checking = false
            checkTask = nil
        }
    }

    private func openGuide() {
        do {
            _ = try AppInspectionCenter().openLink(
                AppInspectionCenter.extensionDocumentationID(
                    extensionID: "herdr", documentID: "guide"),
                contributors: [])
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct CompanionRows: View {
    @AppStorage(AppStorageKeys.Tabs.companionEnabled, store: SharedDefaults.store) private
        var enabled = false

    var body: some View {
        Section("Workspace") {
            LabeledContent("Content", value: "Notes, voice memos, and activity")
            Text("Search remembered context, capture new material, and manage Companion hosts.")
                .settingsCaption()
            Button("Open Companion") { SectionWindow.open(.companion) }
                .pointerCursor()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct CalendarRows: View {
    @AppStorage(AppStorageKeys.Tabs.calendarEnabled, store: SharedDefaults.store) private
        var enabled = false

    var body: some View {
        Section("Calendar") {
            LabeledContent("Source", value: "macOS Calendar")
            Text("Your agenda appears in Edith after Calendar access is granted.")
                .settingsCaption()
            HStack {
                Button("Open Edith Calendar") { SectionWindow.open(.calendar) }
                    .pointerCursor()
                Button("Open Calendar app") {
                    CalendarEventOperationExecution.openCalendar()
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct QuinjetRows: View {
    @AppStorage(AppStorageKeys.Tabs.quinjetEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.Quinjet.terminal, store: SharedDefaults.store) private
        var terminal = QuinjetTerminal.embedded.rawValue
    @AppStorage(AppStorageKeys.Quinjet.theme, store: SharedDefaults.store) private
        var theme = QuinjetTheme.quinjet.rawValue

    var body: some View {
        CLIToolStatusSection(tools: [.quinjet], extensionEnabled: enabled)

        Section("Launch") {
            Picker(
                "Terminal", selection: $terminal.configured(AppStorageKeys.Quinjet.terminal)
            ) {
                ForEach(QuinjetTerminal.allCases) { option in
                    Label(option.label, systemImage: option.icon)
                        .tag(option.rawValue)
                        .disabled(!option.isAvailable)
                }
            }
            Picker("Theme", selection: $theme.configured(AppStorageKeys.Quinjet.theme)) {
                ForEach(QuinjetTheme.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
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
    let grant: (ExtensionPermission) throws -> Void
    let openSettings: (ExtensionPermission) throws -> Void
    let cancel: () -> Void
    let enable: () -> Void
    let refresh: () -> Void
    @State private var actionError: String?

    private var requiredGranted: Bool {
        request.entry.requiredPermissions.allSatisfy { grantedPermissions[$0] == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(20)) {
            HStack(spacing: UIScale.pt(14)) {
                AppGlyph(request.entry, size: UIScale.pt(22), weight: .medium)
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
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .settingsCaption()
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
                    .settingsCaption()
                if let firstUseExplanation = permission.firstUseExplanation {
                    Text(firstUseExplanation)
                        .settingsCaption()
                }
            }
            Spacer(minLength: 12)
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(.green)
            } else if MainPermissionOperations.center.remediation(for: permission).action
                == .request
            {
                Button("Grant") { requestPermission(permission) }
                    .controlSize(.small)
                    .pointerCursor()
            } else if MainPermissionOperations.center.remediation(for: permission).settingsURL
                != nil
            {
                Button("Open Settings") { openPermissionSettings(permission) }
                    .controlSize(.small)
                    .pointerCursor()
            } else {
                Text("On first use")
                    .settingsCaption()
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

    private func requestPermission(_ permission: ExtensionPermission) {
        do {
            try grant(permission)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func openPermissionSettings(_ permission: ExtensionPermission) {
        do {
            try openSettings(permission)
            actionError = nil
            refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct UsageRows: View {
    @AppStorage(AppStorageKeys.Tabs.usageEnabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Limits.inMenuBar, store: SharedDefaults.store) private
        var limitsInMenuBar = true
    @AppStorage(AppStorageKeys.Limits.claudeEnabled, store: SharedDefaults.store) private
        var claudeEnabled = true
    @AppStorage(AppStorageKeys.Limits.codexEnabled, store: SharedDefaults.store) private
        var codexEnabled = true
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
    @AppStorage(AppStorageKeys.Notify.recovery, store: SharedDefaults.store) private var recovery =
        true
    @AppStorage(AppStorageKeys.Notify.pacingWarning, store: SharedDefaults.store) private
        var pacingWarning = true
    @AppStorage(AppStorageKeys.Notify.pacingHot, store: SharedDefaults.store) private
        var pacingHot = true
    @AppStorage(AppStorageKeys.Notify.reminderSession, store: SharedDefaults.store) private
        var reminderSession =
        false
    @AppStorage(AppStorageKeys.Notify.reminderSessionOffsetMin, store: SharedDefaults.store)
    private var reminderSessionOffset = 30
    @AppStorage(AppStorageKeys.Notify.reminderWeekly, store: SharedDefaults.store) private
        var reminderWeekly =
        false
    @AppStorage(AppStorageKeys.Notify.reminderWeeklyOffsetMin, store: SharedDefaults.store)
    private var reminderWeeklyOffset = 120
    @AppStorage(AppStorageKeys.Notify.tokenExpired, store: SharedDefaults.store) private
        var tokenExpired = true
    @State private var testSent = false

    private var hasProvider: Bool { claudeEnabled || codexEnabled }

    var body: some View {
        CLIToolStatusSection(
            tools: ExtensionRegistry.entries.first { $0.id == "usage" }?.requiredTools ?? [],
            extensionEnabled: enabled)

        UsageMachineRows(extensionEnabled: enabled)

        Section {
            Group {
                Toggle(
                    "Claude limits",
                    isOn: $claudeEnabled.configured(AppStorageKeys.Limits.claudeEnabled)
                )
                .pointerCursor()
                Toggle(
                    "Codex limits",
                    isOn: $codexEnabled.configured(AppStorageKeys.Limits.codexEnabled)
                )
                .pointerCursor()
                Toggle(
                    "Show limits in the menu bar",
                    isOn: $limitsInMenuBar.configured(AppStorageKeys.Limits.inMenuBar)
                )
                .pointerCursor()

                if limitsInMenuBar {
                    if claudeEnabled {
                        LimitWindowChipsRow(
                            title: "Claude shows", provider: .claude,
                            raw: $claudeWindowsRaw.configured(
                                AppStorageKeys.MenuBar.claudeWindows))
                    }
                    if codexEnabled {
                        LimitWindowChipsRow(
                            title: "Codex shows", provider: .codex,
                            raw: $codexWindowsRaw.configured(AppStorageKeys.MenuBar.codexWindows))
                    }
                    Picker(
                        "Style",
                        selection: $limitsStyleRaw.configured(AppStorageKeys.MenuBar.limitsStyle)
                    ) {
                        Text("Stacked").tag("stacked")
                        Text("Tagged").tag("tagged")
                        Text("Slashes").tag("slash")
                    }
                    .pointerCursor()

                    Picker("Color", selection: colorModeBinding) {
                        Text("White").tag("white")
                        Text("Black").tag("black")
                        Text("Custom").tag("custom")
                    }
                    .pointerCursor()

                    if isCustomColor {
                        ColorPicker(
                            "Text (5h / 7d)",
                            selection: hexBinding(
                                $subColorHex.configured(AppStorageKeys.MenuBar.subColorHex)),
                            supportsOpacity: false)
                        ColorPicker(
                            "Low risk",
                            selection: hexBinding(
                                $lowColorHex.configured(AppStorageKeys.MenuBar.lowColorHex)),
                            supportsOpacity: false)
                        ColorPicker(
                            "Medium risk",
                            selection: hexBinding(
                                $midColorHex.configured(AppStorageKeys.MenuBar.midColorHex)),
                            supportsOpacity: false)
                        ColorPicker(
                            "High risk",
                            selection: hexBinding(
                                $highColorHex.configured(AppStorageKeys.MenuBar.highColorHex)),
                            supportsOpacity: false)
                        Toggle(
                            "Smart color",
                            isOn: $smartColor.configured(AppStorageKeys.General.smartColor)
                        )
                        .pointerCursor()
                        if !smartColor {
                            HStack {
                                Text("Thresholds")
                                Spacer()
                                Stepper(
                                    "Warn \(warnPercent)%",
                                    value: $warnPercent.configured(
                                        AppStorageKeys.Limits.warnPercent),
                                    in: 10...critPercent - 5, step: 5
                                )
                                .pointerCursor()
                                Stepper(
                                    "Critical \(critPercent)%",
                                    value: $critPercent.configured(
                                        AppStorageKeys.Limits.critPercent),
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
                isOn: $budgetEnabled.configured(AppStorageKeys.Budget.enabled)
            )
            .pointerCursor()
            Text(
                "Set a personal cap under the real limit and get told if you're spending too fast."
            )
            .settingsCaption()
            if budgetEnabled {
                Picker(
                    "Mode", selection: $budgetMode.configured(AppStorageKeys.Budget.mode)
                ) {
                    Text("Auto daily pace").tag("pace")
                    Text("Cap by a deadline").tag("cap")
                }.pointerCursor()
                Picker(
                    "Window", selection: $budgetKind.configured(AppStorageKeys.Budget.kind)
                ) {
                    Text("Weekly").tag("weekly")
                    Text("Session (5h)").tag("session")
                }.pointerCursor()
                HStack {
                    Text("Cap")
                    Slider(
                        value: $budgetCap.configured(AppStorageKeys.Budget.capPercent),
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
                                $budgetDeadlineTS.configured(AppStorageKeys.Budget.deadline)
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
                .pointerCursor()
            Group {
                Toggle(
                    isOn: $trackSession.configured(AppStorageKeys.Notify.trackSession)
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Session (5h) alerts")
                        InfoDot(
                            "Fires once when the session window crosses warn or critical - it won't repeat while you stay in that zone."
                        )
                    }
                }
                .pointerCursor()
                Toggle(
                    isOn: $trackWeekly.configured(AppStorageKeys.Notify.trackWeekly)
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Weekly alerts")
                        InfoDot(
                            "Fires once when the weekly window crosses warn or critical - same one-shot-per-zone behavior as session alerts."
                        )
                    }
                }
                .pointerCursor()
                Toggle(
                    "Back to green",
                    isOn: $recovery.configured(AppStorageKeys.Notify.recovery)
                )
                .pointerCursor()
                HStack {
                    Text("Pacing margin")
                    Spacer()
                    Stepper(
                        "±\(Int(pacingMargin)) pp",
                        value: $pacingMargin.configured(AppStorageKeys.Limits.pacingMargin),
                        in: 5...25, step: 5
                    )
                    .pointerCursor()
                }
                Toggle(
                    isOn: $pacingWarning.configured(AppStorageKeys.Notify.pacingWarning)
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Drifting / burning hot")
                        InfoDot(
                            "A separate signal from the level alerts above: how far ahead of an even burn-rate pace you are, regardless of the absolute percentage."
                        )
                    }
                }
                .pointerCursor()
                Toggle(
                    "Token expired",
                    isOn: $tokenExpired.configured(AppStorageKeys.Notify.tokenExpired)
                )
                .pointerCursor()
                HStack {
                    Toggle(
                        "Remind before session reset",
                        isOn: $reminderSession.configured(AppStorageKeys.Notify.reminderSession)
                    )
                    .pointerCursor()
                    Picker(
                        "",
                        selection: $reminderSessionOffset.configured(
                            AppStorageKeys.Notify.reminderSessionOffsetMin)
                    ) {
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 h").tag(60)
                    }
                    .labelsHidden().pointerCursor().disabled(!reminderSession)
                }
                HStack {
                    Toggle(
                        "Remind before weekly reset",
                        isOn: $reminderWeekly.configured(AppStorageKeys.Notify.reminderWeekly)
                    )
                    .pointerCursor()
                    Picker(
                        "",
                        selection: $reminderWeeklyOffset.configured(
                            AppStorageKeys.Notify.reminderWeeklyOffsetMin)
                    ) {
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
                    AppRuntimeCenter().request(.testNotification)
                    testSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testSent = false }
                }
                .pointerCursor()
                if testSent {
                    Text("Sent - check Notification Center")
                        .settingsCaption()
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
            if enabled && codexEnabled {
                let center = ExtensionMutationCenter.application
                Task { _ = await center.provision([.codex]) }
            }
            reconcileProviders()
        }
    }

    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { notifyMaster },
            set: { enabled in
                $notifyMaster.configured(AppStorageKeys.Notify.master).wrappedValue = enabled
                if enabled
                    && !SharedDefaults.store.bool(
                        forKey: AppStorageKeys.Permissions.notificationsGranted)
                {
                    _ = try? MainPermissionOperations.center.request(.notifications)
                }
            })
    }

    private var isCustomColor: Bool {
        menuBarColorMode == "custom" || menuBarColorMode == "auto"
    }

    private var colorModeBinding: Binding<String> {
        Binding(
            get: { isCustomColor ? "custom" : menuBarColorMode },
            set: {
                $menuBarColorMode.configured(AppStorageKeys.MenuBar.colorMode).wrappedValue = $0
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
        let state = AgentUsageSettingsFlow.providersChanged(
            AgentUsageSettingsState(
                enabled: enabled, claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
                menuBarEnabled: limitsInMenuBar, alertsEnabled: notifyMaster,
                selectedProvider: selectedProvider))
        enabled = state.enabled
        $limitsInMenuBar.configured(AppStorageKeys.Limits.inMenuBar).wrappedValue =
            state.menuBarEnabled
        $notifyMaster.configured(AppStorageKeys.Notify.master).wrappedValue = state.alertsEnabled
    }
}

private struct SystemStatsRows: View {
    @AppStorage(AppStorageKeys.MenuBar.systemStats, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.MenuBar.statsColorHex, store: SharedDefaults.store) private
        var statsColorHex =
        "FFFFFF"

    var body: some View {
        Section {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { DashPalette.color(statsColorHex) },
                    set: {
                        $statsColorHex.configured(AppStorageKeys.MenuBar.statsColorHex)
                            .wrappedValue =
                            $0.hex6
                    }),
                supportsOpacity: false)
            Text("Sampled every couple of seconds; costs nothing measurable.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct MusicRows: View {
    @AppStorage(AppStorageKeys.Tabs.musicEnabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(MusicFade.enabledKey, store: SharedDefaults.store) private var crossfade = true
    @AppStorage(MusicFade.secondsKey, store: SharedDefaults.store) private var crossfadeSeconds =
        MusicFade.defaultSeconds
    @State private var openError: String?

    var body: some View {
        CLIToolStatusSection(tools: [.youtubeDownloader], extensionEnabled: enabled)

        Section {
            LabeledContent("Music folder") {
                HStack {
                    Button("Choose folder...") { chooseLibrary() }
                        .pointerCursor()
                    Button("Open in Finder") {
                        do {
                            try MusicLibraryOperationExecution.openLibrary()
                            openError = nil
                        } catch {
                            openError = error.localizedDescription
                        }
                    }
                    .pointerCursor()
                }
            }
            if let openError {
                Label(openError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .settingsCaption()
            }
            Toggle(
                "Fade between tracks",
                isOn: $crossfade.configured(MusicFade.enabledKey)
            )
            .pointerCursor()
            if crossfade {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    LabeledContent("Fade length") {
                        Text(String(format: "%.1fs", crossfadeSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $crossfadeSeconds.configured(MusicFade.secondsKey),
                        in: MusicFade.secondsRange
                    )
                    .pointerCursor()
                    Text("How long the old track fades out while the next one fades in.")
                        .settingsCaption()
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your music folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try MusicFolderSelectionOperationExecution.select(url.path)
            openError = nil
        } catch {
            openError = error.localizedDescription
        }
    }
}

private struct MicMuteRows: View {
    @AppStorage(AppStorageKeys.Mic.muteEnabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Mic.muteInMenuBar, store: SharedDefaults.store) private
        var inMenuBar = true

    var body: some View {
        Section {
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
            }
            Text("Use this shortcut to mute or unmute every microphone system-wide.")
                .settingsCaption()
            Toggle(
                "Show in the menu bar",
                isOn: $inMenuBar.configured(AppStorageKeys.Mic.muteInMenuBar)
            )
            .pointerCursor()
            Text("The menu bar icon shows the current mute state and toggles it on click.")
                .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SystemRows: View {
    @AppStorage(AppStorageKeys.Tabs.systemEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.General.preventSleep, store: SharedDefaults.store) private
        var preventSleep = false
    @State private var cleaningStarted = false

    var body: some View {
        Section {
            Toggle(
                isOn: $preventSleep.configured(AppStorageKeys.General.preventSleep)
            ) {
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
                        .settingsCaption()
                }
                Button("Clean now") {
                    AppRuntimeCenter().request(.cleanKeys)
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

private struct LimitWindowChipsRow: View {
    let title: String
    let provider: LimitProvider
    @Binding var raw: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(MenuBarLimits.slots(for: provider), id: \.self) { slot in
                Toggle(slot.settingsLabel, isOn: binding(for: slot))
                    .toggleStyle(.button)
                    .pointerCursor()
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
