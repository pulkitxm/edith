import EdithExtensionUI
import SwiftUI

enum CleanerDrivePicker: Identifiable {
    case scan
    case choose

    var id: Self { self }
}

struct CleanerPage: View {
    @State var model: CleanerModel
    @State private var drivePicker: CleanerDrivePicker?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    static let subtitle =
        "Find build caches, downloads and old worktrees you can safely remove. Nothing is deleted until you confirm."

    var body: some View {
        PageWorkspace {
            VStack(spacing: 0) {
                PageHeader(
                    subtitle: Self.subtitle,
                    title: { Text("Cleaner") },
                    trailing: { headerActions })
                Divider()
            }
        } content: {
            CleanerCard(
                dark: scheme == .dark, compact: compact, model: model,
                pickDrives: { openPicker($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .edithSheet(item: $drivePicker) { picker in
            DrivePickerSheet(
                model: model, dark: scheme == .dark,
                confirmTitle: picker == .scan ? "Scan these locations" : "Done"
            ) {
                if picker == .scan { model.scan() }
            }
        }
        .pageTask {
            while !Task.isCancelled {
                await model.refreshRemote()
                guard !Task.isCancelled else { return }
                let scanning = model.scanning
                do {
                    try await Task.sleep(
                        for: scanning ? .milliseconds(150) : .seconds(3),
                        tolerance: scanning ? .milliseconds(50) : .milliseconds(750))
                } catch { return }
            }
        }
    }

    @ViewBuilder private var headerActions: some View {
        switch model.presentation {
        case .scanning:
            Button {
                model.cancelScan()
            } label: {
                Text("Cancel scan").font(.edithText(.body))
            }
            .buttonStyle(.edith(.secondary))
            .help("Stop scanning. Nothing has been changed.")
            .accessibilityIdentifier("cleaner.cancel")
        case .results where !model.scanning:
            Button {
                openPicker(.scan)
            } label: {
                Label("Scan again", edith: .refresh).font(.edithText(.body))
            }
            .buttonStyle(.edith(.secondary))
            .help("Choose where to search, then look for space you can reclaim again.")
            .accessibilityIdentifier("cleaner.rescan")
        case .firstRun, .nothingToClean, .results:
            EmptyView()
        }
    }

    private func openPicker(_ picker: CleanerDrivePicker) {
        model.loadDriveOptions()
        drivePicker = picker
    }
}
