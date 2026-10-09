import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

enum AppMaintenanceSection: String, CaseIterable, Identifiable {
    case updates = "Updates"
    case packages = "Packages"
    case removal = "Remove"
    case cleaner = "Cleaner"
    case history = "History"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .updates: "arrow.up.circle"
        case .packages: "shippingbox"
        case .removal: "trash"
        case .cleaner: "sparkles.rectangle.stack"
        case .history: "clock.arrow.circlepath"
        }
    }

    var abilityID: String {
        switch self {
        case .packages: "homebrew"
        case .cleaner: "cleaner"
        default: "appMaintenance"
        }
    }

    var usesApplicationInventory: Bool {
        switch self {
        case .packages, .cleaner: false
        case .updates, .removal, .history: true
        }
    }

    var summary: String {
        switch self {
        case .updates: "Review and run available application updates."
        case .packages: "Manage installed and discoverable Homebrew packages."
        case .removal: "Review applications and their related files before removal."
        case .cleaner: "Find reclaimable space and remove it after review."
        case .history: "Review completed maintenance operations."
        }
    }
}

struct AppMaintenanceView: View {
    @State var model: AppMaintenanceModel
    @State private var query = ""
    @State private var confirmingRemoval = false
    @State private var confirmingUpdates = false
    @State private var showingDiskImagePicker = false
    @State private var showingUpdateSettings = false
    @AppStorage(MaintenancePreferences.section, store: SharedDefaults.store)
    private var sectionRaw = AppMaintenanceSection.updates.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(MaintenancePreferences.installDestination, store: SharedDefaults.store)
    private var installDestinationRaw = AppMaintenanceInstallDestination.user.rawValue
    @AppStorage(MaintenancePreferences.updateAutoRefresh, store: SharedDefaults.store)
    private var updateAutoRefresh = false
    @AppStorage(MaintenancePreferences.updateNotifications, store: SharedDefaults.store)
    private var updateNotifications = true
    @AppStorage(MaintenancePreferences.updateRefreshInterval, store: SharedDefaults.store)
    private var updateRefreshInterval = 86_400.0
    @AppStorage(MaintenancePreferences.updateConcurrency, store: SharedDefaults.store)
    private var updateConcurrency = 2
    @AppStorage(MaintenancePreferences.updateRetries, store: SharedDefaults.store)
    private var updateRetries = 1

    private var filteredApplications: [InstalledApplication] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.applications }
        return model.applications.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.bundleID.localizedCaseInsensitiveContains(value)
        }
    }

    private var filteredUpdates: [AppUpdateItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.updates }
        return model.updates.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.source.title.localizedCaseInsensitiveContains(value)
                || $0.bundleID?.localizedCaseInsensitiveContains(value) == true
        }
    }

    private var theme: Color { themeColor(themeName) }

    private var section: AppMaintenanceSection {
        AppMaintenanceSection(rawValue: sectionRaw) ?? .updates
    }

    private var sectionBinding: Binding<AppMaintenanceSection> {
        Binding(
            get: { section },
            set: { sectionRaw = $0.rawValue })
    }

    var body: some View {
        PageWorkspace {
            header
            Divider()
        } content: {
            content
        }
        .pageTask(active: section.usesApplicationInventory, cancel: model.cancel) {
            model.refresh(interval: updateRefreshInterval)
        }
        .pageRefresh(
            active: updateAutoRefresh && section.usesApplicationInventory,
            interval: { .seconds(max(updateRefreshInterval, 900)) }
        ) {
            model.refresh(automatic: true, interval: updateRefreshInterval)
        }
        .fileImporter(
            isPresented: $showingDiskImagePicker,
            allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            model.prepareDiskImage(url, destination: installDestination)
        }
        .edithSheet(item: installPlanBinding, dismissible: model.phase != .installing) { plan in
            AppMaintenanceInstallReview(
                plan: plan, installing: model.phase == .installing,
                onCancel: { model.cancelInstallPlan() },
                onInstall: { replaceExisting, moveImageToTrash in
                    model.installDiskImage(
                        replaceExisting: replaceExisting,
                        moveImageToTrash: moveImageToTrash)
                })
        }
        .alert("Move selected items to the Trash?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeSelected() }
        } message: {
            Text(
                "\(model.selectedItems.count) reviewed items use \(AppMaintenanceFiles.format(model.selectedBytes)). You can restore them from the Trash until it is emptied."
            )
        }
        .alert("Run selected updates?", isPresented: $confirmingUpdates) {
            Button("Cancel", role: .cancel) {}
            Button("Run Updates") {
                model.runSelectedUpdates(
                    concurrency: updateConcurrency, retries: updateRetries)
            }
        } message: {
            Text(
                "\(model.selectedUpdateIDs.count) reviewed updates will run with up to \(updateConcurrency) at once. App-native updaters will open for you to finish."
            )
        }
    }

    private var header: some View {
        PageHeader(
            section.rawValue,
            trailing: {
                Picker("Section", selection: sectionBinding) {
                    ForEach(AppMaintenanceSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(section)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("App Maintenance section")
            },
            accessory: {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    Text(section.summary)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if section.usesApplicationInventory {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: UIScale.pt(10)) {
                                Button {
                                    showingUpdateSettings.toggle()
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .help("Update settings")
                                .edithSheet(isPresented: $showingUpdateSettings) {
                                    updateSettings
                                }
                                Menu {
                                    Picker("Destination", selection: $installDestinationRaw) {
                                        ForEach(
                                            AppMaintenanceInstallDestination.allCases,
                                            id: \.rawValue
                                        ) {
                                            destination in
                                            Text(destination.title).tag(destination.rawValue)
                                        }
                                    }
                                } label: {
                                    Label(installDestination.title, systemImage: "folder")
                                }
                                if model.checkingUpdates {
                                    Text("Checking updates")
                                        .font(.system(size: UIScale.pt(12)))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    showingDiskImagePicker = true
                                } label: {
                                    Label(
                                        "Install Disk Image",
                                        systemImage: "externaldrive.badge.plus")
                                }
                                .disabled(model.phase != .ready)
                                Button {
                                    model.refresh(interval: updateRefreshInterval)
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .disabled(model.phase != .ready)
                                .buttonStyle(.edith(.secondary))
                            }
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if section == .packages {
            extensionLink("Homebrew", id: "homebrew", symbol: "shippingbox")
        } else if section == .cleaner {
            extensionLink("Cleaner", id: "cleaner", symbol: "sparkles.rectangle.stack")
        } else if model.phase == .loading {
            ScrollView {
                PageSkeleton(layout: .list)
                    .pageContent(compact)
            }
        } else if compact {
            VStack(spacing: 0) {
                sectionInventory.frame(height: UIScale.pt(180))
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HSplitView {
                sectionInventory
                    .frame(
                        minWidth: UIScale.pt(260), idealWidth: UIScale.pt(300),
                        maxWidth: UIScale.pt(380),
                        maxHeight: .infinity)
                detail
                    .frame(minWidth: UIScale.pt(360), maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func extensionLink(_ title: String, id: String, symbol: String) -> some View {
        PageScaffold {
            EmptyView()
        } content: {
            ContentStatusView(
                title, message: "Download and enable \(title) in Extensions to use it here.",
                symbol: symbol)
            Button("Open \(title)") { model.openExtension(id) }
                .buttonStyle(.edith(.primary))
            if let message = model.errorMessage {
                PageNotice(message, tone: .error)
            }
        }
    }

    @ViewBuilder
    private var sectionInventory: some View {
        switch section {
        case .updates: updateInventory
        case .packages, .cleaner: EmptyView()
        case .removal: removalInventory
        case .history: historyInventory
        }
    }

    private var removalInventory: some View {
        VStack(spacing: 0) {
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(UIScale.pt(12))
            Divider()
            if filteredApplications.isEmpty {
                ContentStatusView(
                    "No applications", message: "No installed app matches this search.",
                    symbol: "app.dashed")
            } else {
                List(filteredApplications) { application in
                    Button {
                        model.select(application)
                    } label: {
                        AppMaintenanceApplicationRow(application: application)
                    }
                    .buttonStyle(
                        EdithButtonStyle(
                            .selection,
                            selected: model.selectedApplicationID == application.id,
                            tint: theme)
                    )
                    .listRowBackground(Color.clear)
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Text("\(model.applications.count) applications")
                Spacer()
                let updates = model.applications.filter { $0.update != nil }.count
                if updates > 0 { Text("\(updates) updates") }
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var updateInventory: some View {
        VStack(spacing: 0) {
            TextField("Search updates", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(UIScale.pt(12))
            Divider()
            if filteredUpdates.isEmpty {
                ContentStatusView(
                    "No updates", message: "Everything visible is current, ignored, or snoozed.",
                    symbol: "checkmark.circle")
            } else {
                List(filteredUpdates) { item in
                    HStack(spacing: UIScale.pt(9)) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.selectedUpdateIDs.contains(item.id) },
                                set: { model.setUpdateSelected($0, item: item) })
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        Button {
                            model.focusedUpdateID = item.id
                        } label: {
                            HStack(spacing: UIScale.pt(9)) {
                                if let path = item.applicationPath {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                        .resizable()
                                        .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                                } else {
                                    Image(systemName: "shippingbox")
                                        .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                                }
                                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                    Text(item.name).lineLimit(1)
                                    Text("\(item.currentVersion) → \(item.availableVersion)")
                                        .settingsCaption()
                                }
                                Spacer(minLength: 0)
                                Text(item.source.title).settingsCaption().lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(
                            EdithButtonStyle(
                                .borderless, selected: model.focusedUpdateID == item.id,
                                tint: theme))
                    }
                    .padding(.vertical, UIScale.pt(3))
                    .listRowBackground(
                        model.focusedUpdateID == item.id ? theme.opacity(0.2) : Color.clear)
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Text("\(model.updates.count) available")
                Spacer()
                Text("\(model.selectedUpdateIDs.count) selected")
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var historyInventory: some View {
        Group {
            if model.updateHistory.isEmpty {
                ContentStatusView(
                    "No Update History", message: "Completed update attempts will appear here.",
                    symbol: "clock")
            } else {
                List(model.updateHistory, id: \.finishedAt) { result in
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        HStack {
                            Text(result.name).lineLimit(1)
                            Spacer()
                            Image(
                                systemName: result.status == .succeeded
                                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                            )
                            .foregroundStyle(result.status == .succeeded ? .green : .orange)
                        }
                        Text("\(result.version) · \(result.source.title)").settingsCaption()
                        Text(result.finishedAt, style: .relative).settingsCaption()
                    }
                    .padding(.vertical, UIScale.pt(4))
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var installDestination: AppMaintenanceInstallDestination {
        AppMaintenanceInstallDestination(rawValue: installDestinationRaw) ?? .user
    }

    private var installPlanBinding: Binding<AppMaintenanceDiskImagePlan?> {
        Binding(
            get: { model.installPlan },
            set: { value in
                if value == nil, model.installPlan != nil { model.cancelInstallPlan() }
            })
    }

    private var progressMessage: String {
        switch model.phase {
        case .removing: "Moving selected items"
        case .mounting: "Mounting and verifying disk image"
        case .updating: "Running reviewed updates"
        default: "Finding exact support files"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .updates: updateDetail
        case .packages, .cleaner: EmptyView()
        case .removal: removalDetail
        case .history: historyDetail
        }
    }

    @ViewBuilder
    private var removalDetail: some View {
        if model.phase == .scanning {
            PageSkeleton(layout: .list)
        } else if model.phase == .removing || model.phase == .mounting {
            ZStack(alignment: .top) {
                PageSkeleton(layout: .list)
                Text(progressMessage)
                    .settingsCaption()
                    .padding(.top, UIScale.pt(8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let application = model.selectedApplication, let plan = model.plan {
            removalPlan(application: application, plan: plan)
        } else {
            VStack(spacing: UIScale.pt(14)) {
                Image(systemName: "checklist")
                    .font(.system(size: UIScale.pt(44), weight: .light))
                    .foregroundStyle(.secondary)
                Text("Choose an application")
                    .font(.edithText(.headline))
                Text(
                    "Edith will show the app and exact bundle-identifier matches before anything moves."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: UIScale.pt(360))
                statusMessage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(UIScale.pt(28))
        }
    }

    @ViewBuilder
    private var updateDetail: some View {
        if model.phase == .updating {
            ZStack(alignment: .bottomLeading) {
                SkeletonGroup {
                    PageSkeleton(layout: .cards)
                }
                Button("Cancel") { model.cancel() }
                    .padding(UIScale.pt(22))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = model.focusedUpdate {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                HStack(spacing: UIScale.pt(14)) {
                    if let path = item.applicationPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: UIScale.pt(54), height: UIScale.pt(54))
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(item.name).font(.edithText(.title3).weight(.semibold))
                        Text("\(item.currentVersion) → \(item.availableVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                        Text(item.source.title).fontWeight(.medium)
                        Text("\(item.confidence.title) confidence").settingsCaption()
                    }
                }
                GroupBox("Release") {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        if let title = item.releaseTitle { Text(title).fontWeight(.medium) }
                        ScrollView {
                            Text(
                                item.releaseNotes
                                    ?? "Release notes are not available from this source."
                            )
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: UIScale.pt(180))
                        if let releaseURL = item.releaseURL {
                            Link("Open release information", destination: releaseURL)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(6))
                }
                GroupBox("Reviewed action") {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text(item.command).font(.edithText(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(
                            "Checked \(item.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .settingsCaption()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(6))
                }
                statusMessage
                Spacer()
                HStack {
                    Menu("More") {
                        Button("Copy Command") { copy(item.command) }
                        if let path = item.applicationPath {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: path)
                                ])
                            }
                        }
                        Button("Ignore \(item.availableVersion)") { model.ignore(item) }
                        Button("Snooze for One Day") {
                            model.snooze(item, until: Date().addingTimeInterval(86_400))
                        }
                        if item.bundleID != nil {
                            Button("Exclude This App") { model.exclude(item) }
                        }
                    }
                    Spacer()
                    Button(
                        item.action == .openUpdater && model.selectedUpdateIDs.count == 1
                            ? "Open App Updater"
                            : "Run \(model.selectedUpdateIDs.count) Updates"
                    ) {
                        confirmingUpdates = true
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(model.selectedUpdateIDs.isEmpty)
                }
            }
            .padding(UIScale.pt(22))
        } else {
            ContentStatusView(
                "Select an update",
                message: "Choose updates to review their source, command, and release information.",
                symbol: "arrow.down.app")
        }
    }

    private var historyDetail: some View {
        VStack(spacing: UIScale.pt(14)) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: UIScale.pt(44), weight: .light))
                .foregroundStyle(.secondary)
            Text("Update History").font(.edithText(.headline))
            Text("Each attempt records its source, version, retries, result, and finish time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: UIScale.pt(380))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var updateSettings: some View {
        Form {
            Toggle("Automatic refresh", isOn: $updateAutoRefresh)
            Picker("Refresh", selection: $updateRefreshInterval) {
                Text("Hourly").tag(3_600.0)
                Text("Daily").tag(86_400.0)
                Text("Weekly").tag(604_800.0)
            }
            .disabled(!updateAutoRefresh)
            Toggle("Notifications", isOn: $updateNotifications)
            Stepper("Concurrency: \(updateConcurrency)", value: $updateConcurrency, in: 1...4)
            Stepper("Retries: \(updateRetries)", value: $updateRetries, in: 0...3)
            Button("Reset Ignored, Snoozed, and Excluded Apps") {
                model.resetUpdatePolicies()
            }
            Text("Automatic refresh only checks. Updates always require an explicit action.")
                .settingsCaption()
        }
        .edithForm()
        .frame(width: UIScale.pt(360), height: UIScale.pt(300))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func removalPlan(
        application: InstalledApplication, plan: AppMaintenancePlan
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .frame(width: UIScale.pt(48), height: UIScale.pt(48))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(application.name)
                        .font(.system(size: UIScale.pt(17), weight: .semibold))
                    Text("\(application.bundleID) · \(application.version)")
                        .settingsCaption()
                    if let update = application.update {
                        Label(
                            "\(update.latestVersion) available through \(update.source)",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.edithText(.caption))
                        .foregroundStyle(.green)
                    }
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([application.url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            .padding(UIScale.pt(18))
            Divider()
            List {
                ForEach(AppMaintenanceCategory.allCases, id: \.self) { category in
                    let items = plan.items.filter { $0.category == category }
                    if !items.isEmpty {
                        Section(category.rawValue) {
                            ForEach(items) { item in
                                AppMaintenanceItemRow(
                                    item: item,
                                    selected: Binding(
                                        get: { model.selectedItemIDs.contains(item.id) },
                                        set: { model.setSelected($0, item: item) }))
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(spacing: UIScale.pt(8)) {
                statusMessage
                HStack {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("\(model.selectedItems.count) of \(plan.items.count) selected")
                            .fontWeight(.medium)
                        Text(AppMaintenanceFiles.format(model.selectedBytes))
                            .settingsCaption()
                    }
                    Spacer()
                    Button("Move to Trash", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .buttonStyle(.edith(.destructive))
                    .disabled(model.selectedItems.isEmpty)
                }
            }
            .padding(UIScale.pt(16))
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.edithText(.caption))
                .foregroundStyle(.red)
        } else if let message = model.resultMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.edithText(.caption))
                .foregroundStyle(.green)
        }
    }
}

private struct AppMaintenanceApplicationRow: View {
    let application: InstalledApplication

    var body: some View {
        HStack(spacing: UIScale.pt(9)) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable()
                .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(application.name)
                    .lineLimit(1)
                Text(application.version)
                    .settingsCaption()
            }
            Spacer(minLength: 0)
            if application.update != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .help("Update available")
            }
        }
        .padding(.vertical, UIScale.pt(3))
    }
}

private struct AppMaintenanceItemRow: View {
    let item: AppMaintenanceItem
    @Binding var selected: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Toggle("", isOn: $selected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(
                    (item.url.deletingLastPathComponent().path as NSString)
                        .abbreviatingWithTildeInPath
                )
                .settingsCaption()
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer()
            Text(AppMaintenanceFiles.format(item.sizeBytes))
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.edith(.borderless))
            .help("Reveal in Finder")
        }
    }
}

private struct AppMaintenanceInstallReview: View {
    let plan: AppMaintenanceDiskImagePlan
    let installing: Bool
    let onCancel: () -> Void
    let onInstall: (Bool, Bool) -> Void
    @State private var replaceExisting = false
    @State private var moveImageToTrash = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.sourceApplication.url.path))
                    .resizable()
                    .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text("Install \(plan.sourceApplication.name)")
                        .font(.system(size: UIScale.pt(18), weight: .semibold))
                    Text(
                        "\(plan.sourceApplication.bundleID) · \(plan.sourceApplication.version)"
                    )
                    .settingsCaption()
                }
                Spacer()
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .padding(UIScale.pt(20))
            Divider()
            Form {
                Section("Reviewed installation") {
                    LabeledContent("Disk image", value: plan.imageURL.lastPathComponent)
                    LabeledContent(
                        "Image size", value: AppMaintenanceFiles.format(plan.imageSizeBytes))
                    LabeledContent("Destination", value: plan.destinationURL.path)
                    LabeledContent("Code signature", value: "Accepted")
                    LabeledContent("Gatekeeper", value: "Accepted")
                }
                if let existing = plan.existingApplication {
                    Section("Existing application") {
                        LabeledContent("Installed version", value: existing.version)
                        Text(
                            "The existing app will move to the Trash before the verified replacement is installed."
                        )
                        .settingsCaption()
                        Toggle("Replace the existing application", isOn: $replaceExisting)
                    }
                }
                Section("Cleanup") {
                    Toggle("Move the disk image to Trash after ejecting", isOn: $moveImageToTrash)
                    Text(
                        "The app is staged and verified again before installation. The download only moves after the mounted image ejects successfully."
                    )
                    .settingsCaption()
                }
            }
            .edithForm()
            Divider()
            HStack {
                if installing {
                    SkeletonGroup {
                        SkeletonBlock(width: 16, height: 16, corner: 8)
                    }
                    Text("Installing verified application")
                        .settingsCaption()
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(installing)
                Button(plan.replacesExisting ? "Replace App" : "Install App") {
                    onInstall(replaceExisting, moveImageToTrash)
                }
                .buttonStyle(.edith(.primary))
                .disabled(installing || plan.replacesExisting && !replaceExisting)
            }
            .padding(UIScale.pt(16))
        }
        .frame(width: PresentationMetrics.width(620), height: PresentationMetrics.height(560))
        .interactiveDismissDisabled(installing)
    }
}
