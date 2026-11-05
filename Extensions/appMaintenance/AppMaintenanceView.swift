import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

enum AppMaintenanceSection: String, CaseIterable, Identifiable {
    case updates = "Updates"
    case removal = "Remove"
    case history = "History"

    var id: Self { self }

    var reviewsSelection: Bool { self != .history }

    init(hostSection: String?) {
        self = hostSection.flatMap(Self.init(rawValue:)) ?? .updates
    }

    var uiScope: AppMaintenanceUIScope {
        switch self {
        case .removal: .removal
        case .history: .history
        case .updates: .updates
        }
    }
}

struct AppMaintenanceView: View {
    @State var model: AppMaintenanceModel
    let section: AppMaintenanceSection
    @State private var query = ""
    @State private var confirmingRemoval = false
    @State private var confirmingUpdates = false
    @State private var showingDiskImagePicker = false
    @State private var showingUpdateSettings = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    private var installDestinationRaw: String {
        get { model.preferences.installDestination }
        nonmutating set { model.updatePreferences { $0.installDestination = newValue } }
    }
    private var updateAutoRefresh: Bool {
        get { model.preferences.autoRefresh }
        nonmutating set { model.updatePreferences { $0.autoRefresh = newValue } }
    }
    private var updateNotifications: Bool {
        get { model.preferences.notifications }
        nonmutating set { model.updatePreferences { $0.notifications = newValue } }
    }
    private var updateRefreshInterval: Double {
        get { model.preferences.refreshInterval }
        nonmutating set { model.updatePreferences { $0.refreshInterval = newValue } }
    }
    private var updateConcurrency: Int {
        get { model.preferences.concurrency }
        nonmutating set { model.updatePreferences { $0.concurrency = newValue } }
    }
    private var updateRetries: Int {
        get { model.preferences.retries }
        nonmutating set { model.updatePreferences { $0.retries = newValue } }
    }

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

    private var applicationRows: [AppMaintenanceApplicationRowItem] {
        filteredApplications.map { application in
            AppMaintenanceApplicationRowItem(
                application: application, selected: model.selectedApplicationID == application.id)
        }
    }

    private var updateRows: [AppMaintenanceUpdateRowItem] {
        filteredUpdates.map { item in
            AppMaintenanceUpdateRowItem(
                item: item, selected: model.selectedUpdateIDs.contains(item.id),
                focused: model.focusedUpdateID == item.id)
        }
    }

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        PageWorkspace {
            PageSubtitle(section.summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pageGutter(compact)
                .padding(.top, UIScale.pt(16))
                .padding(.bottom, UIScale.pt(12))
            if section.reviewsSelection { toolbar }
            Divider()
        } content: {
            content
        }
        .onChange(of: section, initial: true) { _, section in model.scope = section.uiScope }
        .onChange(of: model.focusedUpdateID) { Task { await model.refreshRemote() } }
        .pageRefresh(interval: {
            AppMaintenanceRefresh.interval(busy: model.phase != .ready || model.checkingUpdates)
        }) {
            await model.refreshRemote()
        }
        .pageTask(cancel: model.cancelDiscovery) {
            model.refresh(interval: updateRefreshInterval)
        }
        .pageRefresh(
            active: updateAutoRefresh,
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
                model: model, plan: plan, installing: model.phase == .installing,
                onCancel: { model.cancelInstallPlan() },
                onInstall: { replaceExisting, moveImageToTrash in
                    model.installDiskImage(
                        replaceExisting: replaceExisting,
                        moveImageToTrash: moveImageToTrash)
                })
        }
        .alert(
            "Move \(model.selectedItems.count) \(model.selectedItems.count == 1 ? "item" : "items") to the Trash?",
            isPresented: $confirmingRemoval
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeSelected() }
        } message: {
            Text(
                "\(model.selectedApplication?.name ?? "The app") and the \(AppMaintenanceFiles.format(model.selectedBytes)) you ticked will go to the Trash. You can restore them until you empty it."
            )
        }
        .alert(
            "Update \(model.selectedUpdateIDs.count) \(model.selectedUpdateIDs.count == 1 ? "app" : "apps")?",
            isPresented: $confirmingUpdates
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Run Updates") {
                model.runSelectedUpdates(
                    concurrency: updateConcurrency, retries: updateRetries)
            }
        } message: {
            Text(
                "The ticked updates run with up to \(updateConcurrency) at once. Apps with their own updater open it so you can finish there. Nothing else on your Mac changes."
            )
        }
    }

    private var toolbar: some View {
        WrapHStack(spacing: UIScale.pt(10), lineSpacing: UIScale.pt(8)) {
            Button {
                model.refresh(interval: updateRefreshInterval)
            } label: {
                Label(
                    model.checkingUpdates ? "Checking…" : "Check for updates",
                    systemImage: "arrow.clockwise")
            }
            .disabled(model.phase != .ready || model.checkingUpdates)
            .buttonStyle(.edith(.secondary))
            .help(
                model.phase != .ready || model.checkingUpdates
                    ? "Wait for the current task to finish."
                    : "Look for newer versions of your apps and Homebrew packages.")
            Button {
                showingDiskImagePicker = true
            } label: {
                Label("Install from disk image…", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.edith(.secondary))
            .disabled(model.phase != .ready)
            .help(
                model.phase != .ready
                    ? "Wait for the current task to finish."
                    : "Choose a downloaded .dmg. Edith verifies the app inside before installing it."
            )
            Menu {
                Picker(
                    "Install apps to",
                    selection: Binding(
                        get: { installDestinationRaw },
                        set: { installDestinationRaw = $0 })
                ) {
                    ForEach(AppMaintenanceInstallDestination.allCases, id: \.rawValue) {
                        destination in
                        Text(destination.title).tag(destination.rawValue)
                    }
                }
            } label: {
                Label("Install to: \(installDestination.title)", systemImage: "folder")
            }
            .help("Where apps from disk images are installed.")
            Button {
                showingUpdateSettings.toggle()
            } label: {
                Label("Update settings", systemImage: "gearshape")
            }
            .buttonStyle(.edith(.secondary))
            .popover(isPresented: $showingUpdateSettings) { updateSettings }
            if let checked = model.lastUpdateRefresh, !model.checkingUpdates {
                Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGutter(compact)
        .padding(.bottom, UIScale.pt(PageMetrics.headerBottom))
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .loading {
            ScrollView {
                PageSkeleton(layout: .list)
                    .pageContent(compact)
            }
        } else if section == .updates, updatesState != .list {
            updatesStateView.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !section.reviewsSelection {
            sectionInventory.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if compact {
            VStack(spacing: 0) {
                sectionInventory.frame(height: UIScale.pt(240))
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

    private var updatesState: AppMaintenanceUpdatesState {
        AppMaintenanceUpdatesState(
            loading: model.phase == .loading, checking: model.checkingUpdates,
            hasUpdates: !model.updates.isEmpty, matchesFilter: !filteredUpdates.isEmpty,
            hasError: model.errorMessage != nil, checkedBefore: model.lastUpdateRefresh != nil)
    }

    @ViewBuilder
    private var updatesStateView: some View {
        switch updatesState {
        case .checking:
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                Text("Checking your apps and Homebrew packages…")
                    .font(.edithText(.headline))
                Text("This can take a minute. You can leave this page; the check keeps going.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
                PageSkeleton(layout: .list)
                Button("Cancel check") { model.cancel() }.buttonStyle(.edith(.secondary))
            }
            .pageContent(compact)
        case .failed:
            PageEmptyState(
                symbolName: "exclamationmark.triangle",
                title: "Updates could not be checked",
                message: model.errorMessage ?? "Something went wrong while looking for updates.",
                primary: PageAction(
                    "Try again", symbolName: "arrow.clockwise", identifier: "updates.retry"
                ) {
                    model.refresh(interval: updateRefreshInterval)
                })
        case .neverChecked:
            PageEmptyState(
                symbolName: "arrow.down.app",
                title: "Find out which apps are out of date",
                message:
                    "Edith looks at the apps on this Mac and your Homebrew packages, and lists the ones with a newer version. Checking never installs anything.",
                steps: [
                    PageGuideStep(
                        symbolName: "arrow.clockwise", title: "Check",
                        detail: "Reads your apps and asks each source for the latest version."),
                    PageGuideStep(
                        symbolName: "checklist", title: "Review",
                        detail: "See release notes and the exact command before you run anything."),
                    PageGuideStep(
                        symbolName: "arrow.up.circle", title: "Update",
                        detail: "Tick the ones you want and run them together."),
                ],
                primary: PageAction(
                    "Check for updates", symbolName: "arrow.clockwise", identifier: "updates.check"
                ) {
                    model.refresh(interval: updateRefreshInterval)
                })
        case .upToDate:
            PageEmptyState(
                symbolName: "checkmark.seal",
                title: "Everything is up to date",
                message:
                    "No newer versions were found. Updates you ignored or snoozed stay hidden; you can bring them back in Update settings.",
                primary: PageAction(
                    "Check again", symbolName: "arrow.clockwise", identifier: "updates.check"
                ) {
                    model.refresh(interval: updateRefreshInterval)
                },
                secondary: PageAction(
                    "Update settings", symbolName: "gearshape", identifier: "updates.settings"
                ) {
                    showingUpdateSettings = true
                },
                footnote: model.lastUpdateRefresh.map {
                    "Last checked \($0.formatted(date: .abbreviated, time: .shortened))."
                })
        case .noMatches:
            PageEmptyState(
                symbolName: "magnifyingglass",
                title: "No updates match your search",
                message: "Clear the search to see all \(model.updates.count) available updates.",
                primary: PageAction("Clear search", identifier: "updates.clear") { query = "" })
        case .list:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sectionInventory: some View {
        switch section {
        case .updates: updateInventory
        case .removal: removalInventory
        case .history: historyInventory
        }
    }

    private var removalInventory: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "Search your apps", text: $query)
                .padding(UIScale.pt(12))
            Divider()
            if filteredApplications.isEmpty {
                ContentStatusView(
                    model.applications.isEmpty ? "No applications found" : "No match",
                    message: model.applications.isEmpty
                        ? "Edith could not find any installed apps. Check again in a moment."
                        : "No installed app matches \"\(query)\". Try part of its name.",
                    symbol: "app.dashed",
                    actionTitle: model.applications.isEmpty ? "Check again" : "Clear search",
                    action: {
                        if model.applications.isEmpty {
                            model.refresh(interval: updateRefreshInterval)
                        } else {
                            query = ""
                        }
                    }, secondaryTitle: "", secondaryAction: nil)
            } else {
                VirtualList(
                    applicationRows,
                    rowHeight: { _ in AppMaintenanceRowMetrics.application },
                    header: { EmptyView() }
                ) { entry in
                    AppMaintenanceApplicationRow(
                        entry: entry, icon: model.icon(for: entry.application.url.path),
                        tint: theme, select: { model.select(entry.application) })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("\(model.applications.count) applications")
                Spacer()
                let updates = model.applications.filter { $0.update != nil }.count
                if updates > 0 { Text("\(updates) with updates available") }
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var updateInventory: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "Search available updates", text: $query)
                .padding(UIScale.pt(12))
            Divider()
            if filteredUpdates.isEmpty {
                ContentStatusView(
                    "No updates", message: "Everything visible is current, ignored, or snoozed.",
                    symbol: "checkmark.circle")
            } else {
                VirtualList(
                    updateRows,
                    rowHeight: { _ in AppMaintenanceRowMetrics.update },
                    header: { EmptyView() }
                ) { entry in
                    AppMaintenanceUpdateRow(
                        entry: entry,
                        icon: entry.item.applicationPath.map { model.icon(for: $0) },
                        tint: theme,
                        setSelected: { model.setUpdateSelected($0, item: entry.item) },
                        focus: { model.focusedUpdateID = entry.item.id })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("\(model.updates.count) available")
                Spacer()
                Text("\(model.selectedUpdateIDs.count) ticked to update")
            }
            .settingsCaption()
            .padding(.horizontal, UIScale.pt(12))
            .frame(height: UIScale.pt(34))
        }
    }

    private var historyInventory: some View {
        Group {
            if model.updateHistory.isEmpty {
                PageEmptyState(
                    symbolName: "clock.arrow.circlepath",
                    title: "No updates have been run yet",
                    message:
                        "Each time you run updates, the result is saved here, including anything that failed, so you can see what changed and when.",
                    footnote: "Go to Updates to check for newer versions.")
            } else {
                ScrollView {
                    PageCard {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(model.updateHistory.enumerated()), id: \.element.finishedAt
                            ) { index, result in
                                if index > 0 { Divider() }
                                historyRow(result)
                            }
                        }
                    }
                    .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    .pageContent(compact)
                }
            }
        }
    }

    private func historyRow(_ result: AppUpdateResult) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            Image(
                systemName: result.status == .succeeded
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.system(size: UIScale.pt(16)))
            .foregroundStyle(result.status == .succeeded ? DashSkin.sage : DashSkin.warn)
            .accessibilityLabel(result.status == .succeeded ? "Updated" : "Needs attention")
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(result.name).font(.edithText(.body)).fontWeight(.medium).lineLimit(1)
                Text(
                    result.status == .succeeded
                        ? "Updated to \(result.version) with \(result.source.title)"
                        : result.detail.isEmpty ? "The update did not finish." : result.detail
                )
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: UIScale.pt(8))
            Text(result.finishedAt, format: .relative(presentation: .named))
                .font(.edithText(.caption)).monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, UIScale.pt(10))
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
        case .removal: removalDetail
        case .history: EmptyView()
        }
    }

    @ViewBuilder
    private var removalDetail: some View {
        if model.phase == .scanning {
            AppMaintenanceRemovalSkeleton()
        } else if model.phase == .removing || model.phase == .mounting {
            ZStack(alignment: .top) {
                AppMaintenanceRemovalSkeleton()
                Text(progressMessage)
                    .settingsCaption()
                    .padding(.top, UIScale.pt(8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let application = model.selectedApplication, let plan = model.plan {
            removalPlan(application: application, plan: plan)
        } else {
            VStack(spacing: UIScale.pt(0)) {
                PageEmptyState(
                    symbolName: "trash",
                    title: "Choose an app to remove",
                    message:
                        "Pick an app on the left. Edith lists the app and the files it left behind, matched exactly, so nothing unrelated is touched.",
                    steps: [
                        PageGuideStep(
                            symbolName: "app.dashed", title: "Pick an app",
                            detail: "Search or scroll the list."),
                        PageGuideStep(
                            symbolName: "checklist", title: "Review the files",
                            detail: "Untick anything you want to keep."),
                        PageGuideStep(
                            symbolName: "trash", title: "Move to the Trash",
                            detail: "You can restore it until you empty the Trash."),
                    ])
                statusMessage.padding(.bottom, UIScale.pt(16))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var updateDetail: some View {
        if model.phase == .updating {
            ZStack(alignment: .bottomLeading) {
                SkeletonGroup {
                    AppMaintenanceUpdateSkeleton()
                }
                Button("Cancel") { model.cancel() }
                    .padding(UIScale.pt(22))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = model.focusedUpdate {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                HStack(spacing: UIScale.pt(14)) {
                    if let path = item.applicationPath {
                        Image(nsImage: model.icon(for: path))
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
                            .help(
                                "How sure Edith is that this update belongs to the app you have installed."
                            )
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
                GroupBox("What will run") {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        Text(
                            "This is the exact command Edith runs. Apps with their own updater open it instead."
                        )
                        .settingsCaption()
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
                    Menu("More actions") {
                        Button("Copy Command") { copy(item.command) }
                        if let path = item.applicationPath {
                            Button("Reveal in Finder") {
                                model.reveal(URL(fileURLWithPath: path))
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
                            : "Update \(model.selectedUpdateIDs.count) \(model.selectedUpdateIDs.count == 1 ? "app" : "apps")"
                    ) {
                        confirmingUpdates = true
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(model.selectedUpdateIDs.isEmpty)
                    .help(
                        model.selectedUpdateIDs.isEmpty
                            ? "Tick at least one update in the list first."
                            : "You will be asked to confirm before anything runs.")
                }
            }
            .padding(UIScale.pt(22))
        } else {
            ContentStatusView(
                "Select an update",
                message:
                    "Click an update on the left to read its release notes and see exactly what will run.",
                symbol: "arrow.down.app")
        }
    }

    private var updateSettings: some View {
        Form {
            Toggle(
                "Check automatically",
                isOn: Binding(get: { updateAutoRefresh }, set: { updateAutoRefresh = $0 }))
            Picker(
                "Check",
                selection: Binding(
                    get: { updateRefreshInterval }, set: { updateRefreshInterval = $0 })
            ) {
                Text("Hourly").tag(3_600.0)
                Text("Daily").tag(86_400.0)
                Text("Weekly").tag(604_800.0)
            }
            .disabled(!updateAutoRefresh)
            Toggle(
                "Notifications",
                isOn: Binding(get: { updateNotifications }, set: { updateNotifications = $0 }))
            Stepper(
                "Run \(updateConcurrency) at once",
                value: Binding(get: { updateConcurrency }, set: { updateConcurrency = $0 }),
                in: 1...4)
            Stepper(
                "Retry failed updates \(updateRetries) \(updateRetries == 1 ? "time" : "times")",
                value: Binding(get: { updateRetries }, set: { updateRetries = $0 }), in: 0...3)
            Button("Reset Ignored, Snoozed, and Excluded Apps") {
                model.resetUpdatePolicies()
            }
            Text(
                "Automatic refresh only checks for updates and can notify you. Updates always wait for you to run them."
            )
            .settingsCaption()
        }
        .edithForm()
        .frame(width: UIScale.pt(380), height: UIScale.pt(320))
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
                Image(nsImage: model.icon(for: application.url.path))
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
                    model.reveal(application.url)
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
                                    model: model, item: item,
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
                        Text("\(AppMaintenanceFiles.format(model.selectedBytes)) will be freed")
                            .settingsCaption()
                    }
                    Spacer()
                    Button(
                        model.selectedItems.isEmpty
                            ? "Move to Trash"
                            : "Move \(model.selectedItems.count) \(model.selectedItems.count == 1 ? "item" : "items") to Trash",
                        role: .destructive
                    ) {
                        confirmingRemoval = true
                    }
                    .buttonStyle(.edith(.destructive))
                    .disabled(model.selectedItems.isEmpty)
                    .help(
                        model.selectedItems.isEmpty
                            ? "Tick the items you want to remove."
                            : "You will be asked to confirm. Items can be restored from the Trash.")
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

enum AppMaintenanceRowMetrics {
    static var application: CGFloat { CGFloat(UIScale.pt(44)) }
    static var update: CGFloat { CGFloat(UIScale.pt(46)) }
}

struct AppMaintenanceApplicationRowItem: Identifiable, Equatable {
    let application: InstalledApplication
    let selected: Bool
    var id: String { application.id }
}

struct AppMaintenanceUpdateRowItem: Identifiable, Equatable {
    let item: AppUpdateItem
    let selected: Bool
    let focused: Bool
    var id: String { item.id }
}

private struct AppMaintenanceApplicationRow: View {
    let entry: AppMaintenanceApplicationRowItem
    let icon: NSImage
    let tint: Color
    let select: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: select) {
            HStack(spacing: UIScale.pt(9)) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(entry.application.name)
                        .font(.edithText(.body))
                        .foregroundStyle(DashSkin.ink(scheme == .dark))
                        .lineLimit(1)
                    Text(entry.application.version)
                        .font(.edithText(.caption)).monospacedDigit()
                        .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                }
                Spacer(minLength: 0)
                if entry.application.update != nil {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, UIScale.pt(3))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(EdithButtonStyle(.selection, selected: entry.selected, tint: tint))
        .padding(.horizontal, UIScale.pt(8))
        .frame(maxHeight: .infinity)
    }
}

private struct AppMaintenanceUpdateRow: View {
    let entry: AppMaintenanceUpdateRowItem
    let icon: NSImage?
    let tint: Color
    let setSelected: (Bool) -> Void
    let focus: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(9)) {
            Toggle(
                "",
                isOn: Binding(get: { entry.selected }, set: setSelected)
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            Button(action: focus) {
                HStack(spacing: UIScale.pt(9)) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                    } else {
                        Image(systemName: "shippingbox")
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(entry.item.name)
                            .font(.edithText(.body))
                            .foregroundStyle(DashSkin.ink(scheme == .dark))
                            .lineLimit(1)
                        Text("\(entry.item.currentVersion) → \(entry.item.availableVersion)")
                            .font(.edithText(.caption)).monospacedDigit()
                            .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                    }
                    Spacer(minLength: 0)
                    Text(entry.item.source.title)
                        .font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(EdithButtonStyle(.borderless, selected: entry.focused, tint: tint))
        }
        .padding(.horizontal, UIScale.pt(12))
        .frame(maxHeight: .infinity)
        .background(entry.focused ? tint.opacity(0.2) : Color.clear)
    }
}

private struct AppMaintenanceItemRow: View {
    let model: AppMaintenanceModel
    let item: AppMaintenanceItem
    @Binding var selected: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Toggle("", isOn: $selected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: model.icon(for: item.url.path))
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
                model.reveal(item.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.edith(.borderless))
            .help("Reveal in Finder")
        }
    }
}

private struct AppMaintenanceInstallReview: View {
    let model: AppMaintenanceModel
    let plan: AppMaintenanceDiskImagePlan
    let installing: Bool
    let onCancel: () -> Void
    let onInstall: (Bool, Bool) -> Void
    @State private var replaceExisting = false
    @State private var moveImageToTrash = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(12)) {
                Image(nsImage: model.icon(for: plan.sourceApplication.url.path))
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

private struct AppMaintenanceUpdateSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            HStack(spacing: UIScale.pt(14)) {
                SkeletonBlock(width: 54, height: 54, corner: 12)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 156, height: 14)
                    SkeletonBlock(width: 104, height: 9)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 86, height: 10)
                    SkeletonBlock(width: 72, height: 8)
                }
            }
            AppMaintenanceDetailSkeleton(lines: 4, height: 150)
            AppMaintenanceDetailSkeleton(lines: 2, height: 104)
            Spacer(minLength: 0)
            HStack {
                SkeletonBlock(width: 72, height: 30, corner: 7)
                Spacer()
                SkeletonBlock(width: 126, height: 32, corner: 7)
            }
        }
        .padding(UIScale.pt(22))
    }
}

private struct AppMaintenanceHistorySkeleton: View {
    var body: some View {
        VStack(spacing: UIScale.pt(14)) {
            Spacer(minLength: 0)
            SkeletonBlock(width: 44, height: 44, corner: 22)
            SkeletonBlock(width: 154, height: 14)
            VStack(spacing: UIScale.pt(6)) {
                SkeletonBlock(width: 320, height: 9)
                SkeletonBlock(width: 252, height: 9)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(22))
    }
}

private struct AppMaintenanceDetailSkeleton: View {
    let lines: Int
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            SkeletonBlock(width: 94, height: 10)
            ForEach(0..<lines, id: \.self) { index in
                SkeletonBlock(
                    width: index == lines - 1 ? 214 : nil,
                    height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(height), alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}

private struct AppMaintenanceRemovalSkeleton: View {
    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 48, height: 48, corner: 10)
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: 148, height: 14)
                        SkeletonBlock(width: 236, height: 9)
                        SkeletonBlock(width: 184, height: 9)
                    }
                    Spacer()
                    SkeletonBlock(width: 72, height: 28, corner: 7)
                }
                .padding(UIScale.pt(18))
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        SkeletonBlock(width: 76, height: 9)
                        Spacer()
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.top, UIScale.pt(14))
                    .padding(.bottom, UIScale.pt(7))
                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: UIScale.pt(10)) {
                            SkeletonBlock(width: 14, height: 14, corner: 3)
                            SkeletonBlock(width: 22, height: 22, corner: 5)
                            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 132 : 176,
                                    height: 10)
                                SkeletonBlock(width: 248, height: 8)
                            }
                            Spacer()
                            SkeletonBlock(width: 48, height: 8)
                            SkeletonBlock(width: 24, height: 24, corner: 6)
                        }
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(9))
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: 112, height: 10)
                        SkeletonBlock(width: 62, height: 8)
                    }
                    Spacer()
                    SkeletonBlock(width: 104, height: 32, corner: 7)
                }
                .padding(UIScale.pt(16))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Finding exact support files")
    }
}
