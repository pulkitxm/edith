import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HostDataPage: View {
    @Bindable var services: HostCoreServices
    @State private var revision = 0

    var body: some View {
        Form {
            Section("Data root") {
                LabeledContent("Location") {
                    Text(services.identity.root.path).font(.edithText(.caption)).textSelection(
                        .enabled)
                }
                if let footprint = services.snapshot?.storage?.footprints.first(where: {
                    $0.id == "data"
                }) {
                    LabeledContent(
                        "On disk",
                        value: ByteCountFormatter.string(
                            fromByteCount: footprint.bytes, countStyle: .file))
                }
                let backup = services.defaults.double(forKey: AppStorageKeys.Backup.lastBackupAt)
                if backup > 0 {
                    LabeledContent(
                        "Last backup",
                        value: Date(timeIntervalSince1970: backup).formatted(
                            date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button("Open data folder") { NSWorkspace.shared.open(services.identity.root) }
                    Button("Open caches") {
                        NSWorkspace.shared.open(
                            services.identity.root.appendingPathComponent("Caches"))
                    }
                    Button("Open logs") {
                        NSWorkspace.shared.open(
                            services.identity.root.appendingPathComponent("Logs"))
                    }
                }
                Text("Secrets live in Keychain. Caches and logs are regenerable and never synced.")
                    .settingsCaption()
            }
            Section("Measured footprint") {
                if services.inspecting { LoadingIndicator() }
                ForEach(services.snapshot?.storage?.footprints ?? []) { entry in
                    LabeledContent(
                        entry.title,
                        value: ByteCountFormatter.string(
                            fromByteCount: entry.bytes, countStyle: .file))
                }
                if let collectedAt = services.snapshot?.storage?.collectedAt {
                    Text(
                        "Measured \(collectedAt.formatted(date: .abbreviated, time: .shortened)). Sizes refresh on demand."
                    ).settingsCaption()
                }
                Button("Reload") { revision += 1 }.disabled(services.inspecting)
            }
            Section("Restore preview") {
                if let snapshot = services.snapshot?.storage {
                    if snapshot.restoreEntries.isEmpty {
                        Text("No backup files found.").settingsCaption()
                    }
                    ForEach(snapshot.restoreEntries) { entry in
                        LabeledContent(
                            entry.name,
                            value: ByteCountFormatter.string(
                                fromByteCount: entry.bytes, countStyle: .file))
                    }
                }
            }
            if let issues = services.snapshot?.storage?.issues, !issues.isEmpty {
                Section("Partial inspection") {
                    ForEach(issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if let failure = services.failure { Section { Text(failure).foregroundStyle(.orange) } }
        }
        .edithForm()
        .pageTask(id: revision) { await services.inspectStorage() }
    }
}
