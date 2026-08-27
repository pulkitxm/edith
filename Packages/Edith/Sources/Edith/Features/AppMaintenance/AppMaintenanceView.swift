import AppKit
import EdithKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppMaintenanceModel {
    enum Phase: Equatable {
        case loading
        case ready
        case scanning
        case removing
        case mounting
        case installing
    }

    var applications: [InstalledApplication] = []
    var selectedApplicationID: String?
    var plan: AppMaintenancePlan?
    var selectedItemIDs = Set<String>()
    var phase = Phase.loading
    var errorMessage: String?
    var resultMessage: String?
    var installPlan: AppMaintenanceDiskImagePlan?
    private var task: Task<Void, Never>?
    private var securityScopedURL: URL?
    private var hasSecurityScopedAccess = false

    var selectedApplication: InstalledApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    var selectedItems: [AppMaintenanceItem] {
        guard let plan else { return [] }
        var selected: [AppMaintenanceItem] = []
        selected.reserveCapacity(plan.items.count)
        for item in plan.items where selectedItemIDs.contains(item.id) {
            selected.append(item)
        }
        return selected
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func refresh() {
        task?.cancel()
        phase = .loading
        errorMessage = nil
        resultMessage = nil
        task = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                await AppMaintenanceInventory.applicationsWithUpdates()
            }.value
            guard !Task.isCancelled else { return }
            applications = loaded
            phase = .ready
            if let selectedApplicationID,
                !loaded.contains(where: { $0.id == selectedApplicationID })
            {
                self.selectedApplicationID = nil
                plan = nil
                selectedItemIDs = []
            }
        }
    }

    func select(_ application: InstalledApplication) {
        task?.cancel()
        selectedApplicationID = application.id
        plan = nil
        selectedItemIDs = []
        errorMessage = nil
        resultMessage = nil
        phase = .scanning
        task = Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try AppMaintenanceExecution.plan(applicationURL: application.url)
                }.value
                guard !Task.isCancelled, selectedApplicationID == application.id else { return }
                plan = loaded
                selectedItemIDs = Set(loaded.items.map(\.id))
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func setSelected(_ selected: Bool, item: AppMaintenanceItem) {
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    func removeSelected() {
        guard let plan else { return }
        let selectedIDs = selectedItemIDs
        task?.cancel()
        phase = .removing
        errorMessage = nil
        resultMessage = nil
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try AppMaintenanceExecution.remove(plan: plan, selectedIDs: selectedIDs)
                }.value
                guard !Task.isCancelled else { return }
                if result.failed.isEmpty {
                    resultMessage =
                        "Moved \(result.removed.count) items, \(JunkScanner.format(result.reclaimedBytes)), to the Trash."
                } else {
                    resultMessage =
                        "Moved \(result.removed.count) items to the Trash. \(result.failed.count) items could not be moved."
                }
                applications = await Task.detached(priority: .userInitiated) {
                    await AppMaintenanceInventory.applicationsWithUpdates()
                }.value
                selectedApplicationID = nil
                self.plan = nil
                selectedItemIDs = []
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func prepareDiskImage(_ url: URL, destination: AppMaintenanceInstallDestination) {
        task?.cancel()
        cancelInstallPlan()
        phase = .mounting
        errorMessage = nil
        resultMessage = nil
        task = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            var retainedAccess = false
            defer {
                if accessing, !retainedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let prepared = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: url, destination: destination)
                guard !Task.isCancelled else {
                    await AppMaintenanceDiskImageInstaller.cancel(plan: prepared)
                    return
                }
                securityScopedURL = url
                hasSecurityScopedAccess = accessing
                retainedAccess = true
                installPlan = prepared
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func installDiskImage(replaceExisting: Bool, moveImageToTrash: Bool) {
        guard let installPlan else { return }
        task?.cancel()
        phase = .installing
        errorMessage = nil
        resultMessage = nil
        task = Task {
            defer { releaseSecurityScopedAccess() }
            do {
                let result = try await AppMaintenanceDiskImageInstaller.install(
                    plan: installPlan, replaceExisting: replaceExisting,
                    moveImageToTrash: moveImageToTrash)
                guard !Task.isCancelled else { return }
                self.installPlan = nil
                applications = await Task.detached(priority: .userInitiated) {
                    await AppMaintenanceInventory.applicationsWithUpdates()
                }.value
                let cleanup: String
                if !result.ejected {
                    cleanup = " The disk image is still mounted."
                } else if moveImageToTrash, !result.imageMovedToTrash {
                    cleanup = " The disk image was kept."
                } else {
                    cleanup = ""
                }
                resultMessage = "Installed \(result.applicationURL.lastPathComponent).\(cleanup)"
                phase = .ready
            } catch {
                self.installPlan = nil
                guard !Task.isCancelled else {
                    phase = .ready
                    return
                }
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func cancelInstallPlan() {
        if let installPlan {
            self.installPlan = nil
            Task { await AppMaintenanceDiskImageInstaller.cancel(plan: installPlan) }
        }
        releaseSecurityScopedAccess()
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase != .installing { cancelInstallPlan() }
    }

    private func releaseSecurityScopedAccess() {
        if hasSecurityScopedAccess { securityScopedURL?.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
        hasSecurityScopedAccess = false
    }
}

struct AppMaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = AppMaintenanceModel()
    @State private var query = ""
    @State private var confirmingRemoval = false
    @State private var showingDiskImagePicker = false
    @AppStorage(AppStorageKeys.AppMaintenance.installDestination, store: SharedDefaults.store)
    private var installDestinationRaw = AppMaintenanceInstallDestination.user.rawValue

    private var filteredApplications: [InstalledApplication] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.applications }
        return model.applications.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.bundleID.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                inventory
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: UIScale.pt(900), height: UIScale.pt(640))
        .task { model.refresh() }
        .onDisappear { model.cancel() }
        .fileImporter(
            isPresented: $showingDiskImagePicker,
            allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            model.prepareDiskImage(url, destination: installDestination)
        }
        .sheet(item: installPlanBinding) { plan in
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
                "\(model.selectedItems.count) reviewed items use \(JunkScanner.format(model.selectedBytes)). You can restore them from the Trash until it is emptied."
            )
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: UIScale.pt(18), weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("App Maintenance")
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                Text("Install verified disk images, review updates, and remove apps safely.")
                    .settingsCaption()
            }
            Spacer()
            Menu {
                Picker("Destination", selection: $installDestinationRaw) {
                    ForEach(AppMaintenanceInstallDestination.allCases, id: \.rawValue) {
                        destination in
                        Text(destination.title).tag(destination.rawValue)
                    }
                }
            } label: {
                Label(installDestination.title, systemImage: "folder")
            }
            Button {
                showingDiskImagePicker = true
            } label: {
                Label("Install Disk Image", systemImage: "externaldrive.badge.plus")
            }
            .disabled(model.phase != .ready)
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.phase != .ready)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, UIScale.pt(20))
        .frame(height: UIScale.pt(68))
    }

    private var inventory: some View {
        VStack(spacing: 0) {
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(UIScale.pt(12))
            Divider()
            if model.phase == .loading, model.applications.isEmpty {
                ProgressView("Scanning Applications")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApplications.isEmpty {
                ContentUnavailableView(
                    "No applications", systemImage: "app.dashed",
                    description: Text("No installed app matches this search."))
            } else {
                List(filteredApplications, selection: selectionBinding) { application in
                    AppMaintenanceApplicationRow(application: application)
                        .tag(application.id)
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

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedApplicationID },
            set: { value in
                guard let value,
                    let application = model.applications.first(where: { $0.id == value })
                else { return }
                model.select(application)
            })
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
        default: "Finding exact support files"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.phase == .scanning || model.phase == .removing || model.phase == .mounting {
            VStack(spacing: UIScale.pt(12)) {
                ProgressView()
                    .controlSize(.large)
                Text(progressMessage)
                    .foregroundStyle(.secondary)
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
                    .font(.headline)
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
                        .font(.caption)
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
                        Text(JunkScanner.format(model.selectedBytes))
                            .settingsCaption()
                    }
                    Spacer()
                    Button("Move to Trash", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
                .font(.caption)
                .foregroundStyle(.red)
        } else if let message = model.resultMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
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
            Text(JunkScanner.format(item.sizeBytes))
                .font(.caption)
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
                    LabeledContent("Image size", value: JunkScanner.format(plan.imageSizeBytes))
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
            .formStyle(.grouped)
            Divider()
            HStack {
                if installing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing verified application")
                        .settingsCaption()
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(installing)
                Button(plan.replacesExisting ? "Replace App" : "Install App") {
                    onInstall(replaceExisting, moveImageToTrash)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing || plan.replacesExisting && !replaceExisting)
            }
            .padding(UIScale.pt(16))
        }
        .frame(width: UIScale.pt(620), height: UIScale.pt(560))
        .interactiveDismissDisabled(installing)
    }
}
