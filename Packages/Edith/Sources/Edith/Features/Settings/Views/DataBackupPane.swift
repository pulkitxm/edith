import AppKit
import EdithKit
import SwiftUI

@MainActor
@Observable
final class DataBackupModel {
    var footprints: [BackupFootprint] = []
    var lastBackupAt: Date?
    var schemaVersion: Int?
    var restorePreview: [String] = []
    var issues: [String] = []
    var failure: String?
    var isRefreshing = false
    var collectedAt: Date?

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let value = try await StorageInspectionClient().inspect(force: force)
            try Task.checkCancellation()
            footprints = value.footprints
            restorePreview = value.restoreEntries.map {
                "\($0.name) · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"
            }
            issues = value.issues
            collectedAt = value.collectedAt
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            return
        }
        lastBackupAt =
            SharedDefaults.store.object(forKey: AppStorageKeys.Backup.lastBackupAt)
            as? Date
        schemaVersion = await AgentQuery.optional {
            try AgentClient.shared.runtimeSnapshot()
        }?.schemaVersion
    }

    var totalBytes: Int64 {
        footprints.first { $0.id == "data" }?.bytes ?? 0
    }
}

struct DataBackupPane: View {
    @State private var model = DataBackupModel()
    @State private var refreshRevision = 0
    @AppStorage(AppStorageKeys.Backup.icloud, store: SharedDefaults.store) private var icloud = true
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Form {
            rootSection
            classesSection
            footprintSection
            restoreSection
            if let failure = model.failure {
                Section { Text(failure).foregroundStyle(.orange) }
            }
            if !model.issues.isEmpty {
                Section("Partial inspection") {
                    ForEach(model.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: refreshRevision) {
            guard automaticActionsEnabled else { return }
            await model.refresh(force: refreshRevision > 0)
        }
    }

    private var rootSection: some View {
        Section("Data root") {
            LabeledContent("Location") {
                Text(DataRoot.support.path)
                    .font(DashSkin.mono(10.5))
                    .textSelection(.enabled)
            }
            LabeledContent(
                "On disk",
                value: ByteCountFormatter.string(
                    fromByteCount: model.totalBytes, countStyle: .file))
            if let schemaVersion = model.schemaVersion {
                LabeledContent("Store schema", value: "version \(schemaVersion)")
            }
            if let lastBackupAt = model.lastBackupAt {
                LabeledContent(
                    "Last backup",
                    value: lastBackupAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
            HStack {
                Button("Open data folder") {
                    NSWorkspace.shared.open(DataRoot.support)
                }
                Button("Open caches") { NSWorkspace.shared.open(DataRoot.caches) }
                Button("Open logs") { NSWorkspace.shared.open(DataRoot.logs) }
            }
            Text(
                "Caches and logs are regenerable and never synced. Logs older than seven days "
                    + "are pruned on launch."
            )
            .settingsCaption()
        }
    }

    private var classesSection: some View {
        Section("What goes to iCloud") {
            Toggle("Back up to iCloud", isOn: $icloud.configured(AppStorageKeys.Backup.icloud))
            ForEach(BackupCatalog.classes) { backupClass in
                BackupClassRow(backupClass: backupClass, icloud: icloud, dark: dark)
            }
            Text("Secrets stay in the Keychain and are re-entered on each Mac.")
                .settingsCaption()
        }
    }

    private var footprintSection: some View {
        Section("On disk") {
            ForEach(model.footprints) { footprint in
                LabeledContent(footprint.title) {
                    HStack(spacing: UIScale.pt(8)) {
                        Text(
                            footprint.exists
                                ? ByteCountFormatter.string(
                                    fromByteCount: footprint.bytes, countStyle: .file)
                                : "not created"
                        )
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(footprint.exists ? .secondary : .tertiary)
                    }
                }
            }
            if model.isRefreshing {
                SkeletonGroup {
                    SkeletonBlock(width: 180, height: 9, corner: 4)
                }
                .accessibilityLabel("Inspecting storage in the background")
            }
            if let collectedAt = model.collectedAt {
                Text("Measured \(collectedAt.formatted(date: .omitted, time: .shortened))")
                    .settingsCaption()
            }
            Button("Refresh sizes") { refreshRevision &+= 1 }
                .disabled(model.isRefreshing)
        }
    }

    private var restoreSection: some View {
        Section("Restore") {
            if model.collectedAt == nil {
                Text(
                    model.isRefreshing
                        ? "Checking backup files…" : "Backup files have not been inspected."
                )
                .settingsCaption()
            } else if model.restorePreview.isEmpty {
                Text("No iCloud backup was found for this account.")
                    .settingsCaption()
            } else {
                ForEach(model.restorePreview, id: \.self) { line in
                    Text(line)
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Restoring merges rather than replaces: newest wins per settings key, and "
                        + "records union by their id."
                )
                .settingsCaption()
            }
            Button("Reload preview") { refreshRevision &+= 1 }
                .disabled(model.isRefreshing)
        }
    }
}

private struct BackupClassRow: View {
    let backupClass: BackupClass
    let icloud: Bool
    let dark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(backupClass.title)
                        .font(.system(size: UIScale.pt(12.5)))
                    if backupClass.carriesSecrets {
                        Text("minus secrets")
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                Text("\(backupClass.location) · \(backupClass.merge.title)")
                    .font(DashSkin.mono(10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(backupClass.retention)
                .font(DashSkin.mono(10))
                .foregroundStyle(.tertiary)
            if let defaultsKey = backupClass.defaultsKey, backupClass.sync != .never {
                BackupClassToggle(defaultsKey: defaultsKey, dark: dark)
                    .disabled(!icloud)
            } else {
                Text(backupClass.sync.title)
                    .font(DashSkin.mono(10, weight: .medium))
                    .foregroundStyle(
                        backupClass.sync == .never
                            ? DashSkin.inkFaint(dark) : DashSkin.accent(dark)
                    )
                    .frame(width: UIScale.pt(52), alignment: .trailing)
            }
        }
    }
}

private struct BackupClassToggle: View {
    let defaultsKey: String
    let dark: Bool
    @ExtensionEnablementStorage private var enabled: Bool

    init(defaultsKey: String, dark: Bool) {
        self.defaultsKey = defaultsKey
        self.dark = dark
        _enabled = ExtensionEnablementStorage(defaultsKey: defaultsKey)
    }

    var body: some View {
        Toggle("", isOn: $enabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DashSkin.accent(dark))
            .frame(width: UIScale.pt(52), alignment: .trailing)
    }
}
