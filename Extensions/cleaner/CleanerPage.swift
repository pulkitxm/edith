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

    var body: some View {
        PageWorkspace {
            PageHeader(
                title: { Text("Cleaner") },
                trailing: {
                    if model.presentation == .scanning || model.presentation == .results {
                        headerActions
                    }
                },
                accessory: { PageSubtitle(subtitle) })
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

    private var subtitle: String {
        switch model.presentation {
        case .firstRun:
            "Finds caches and leftovers you can safely remove. Nothing is deleted until you confirm."
        case .scanning:
            "Looking for space you can get back. Nothing is changed while it scans."
        case .nothingToClean:
            "The last scan found nothing worth removing."
        case .results:
            "Tick what you want gone, then clean. Everything goes to the Trash first."
        }
    }

    @ViewBuilder private var headerActions: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.scanning {
                Button(model.operationTitle.hasPrefix("Moving") ? "Working…" : "Cancel scan") {
                    model.cancelScan()
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.operationTitle.hasPrefix("Moving"))
                .help(
                    model.operationTitle.hasPrefix("Moving")
                        ? "Items are being moved to the Trash and this cannot be cancelled."
                        : "Stop scanning. Nothing has been changed.")
            } else {
                Button("Choose where to search…") { openPicker(.choose) }
                    .buttonStyle(.edith(.secondary))
                    .help("Pick the drives and folders that are searched for project leftovers.")
                Button(
                    model.scanned ? "Scan again" : "Scan my Mac",
                    systemImage: model.scanned ? "arrow.clockwise" : "magnifyingglass"
                ) { openPicker(.scan) }
                .buttonStyle(.edith(.primary))
                .help("Choose where to search, then look for space you can reclaim.")
            }
        }
    }

    private func openPicker(_ picker: CleanerDrivePicker) {
        model.loadDriveOptions()
        drivePicker = picker
    }
}
