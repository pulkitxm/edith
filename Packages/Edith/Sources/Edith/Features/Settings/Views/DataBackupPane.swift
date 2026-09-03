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

    func refresh() async {
        footprints = BackupFootprintReader.entries()
        lastBackupAt =
            SharedDefaults.store.object(forKey: AppStorageKeys.Backup.lastBackupAt)
            as? Date
        schemaVersion = await AgentQuery.optional {
            try AgentClient.shared.runtimeSnapshot()
        }?.schemaVersion
    }

    func loadRestorePreview() {
        restorePreview = BackupRestorePreview.lines()
    }

    var totalBytes: Int64 {
        footprints.reduce(0) { $0 + $1.bytes }
    }
}

enum BackupRestorePreview {
    static func lines(
        cloudDirectory: URL = AppData.cloudDir, fileManager: FileManager = .default
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: cloudDirectory.path)
        else { return [] }
        return names.filter { $0 != ".DS_Store" }.sorted().map { name in
            let url = cloudDirectory.appendingPathComponent(name)
            let bytes = BackupFootprintReader.size(of: url, fileManager: fileManager)
            return "\(name) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
    }
}

struct DataBackupPane: View {
    @State private var model = DataBackupModel()
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
        }
        .formStyle(.grouped)
        .task {
            guard automaticActionsEnabled else { return }
            await model.refresh()
            model.loadRestorePreview()
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
            Button("Refresh sizes") { Task { await model.refresh() } }
        }
    }

    private var restoreSection: some View {
        Section("Restore") {
            if model.restorePreview.isEmpty {
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
            Button("Reload preview") { model.loadRestorePreview() }
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
