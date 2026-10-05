import AppKit
import EdithKit
import SwiftUI

struct CodeStatsExportSheet: View {
    let snapshot: CodeStatsExportSnapshot
    let onDismiss: () -> Void

    @State private var card = CodeStatsExportCard.highlights
    @State private var preview: NSImage?
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("Share code stats")
                .font(.title3.weight(.semibold))
            Picker("Card", selection: $card) {
                ForEach(CodeStatsExportCard.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            previewView
            HStack(spacing: UIScale.pt(10)) {
                if let status {
                    Label(
                        status,
                        systemImage: failed
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                }
                Spacer()
                Button("Copy image") { copyImage() }
                Button("Save PNG") { saveImage() }
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(640))
        .task(id: card) { await loadPreview() }
    }

    @ViewBuilder
    private var previewView: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .aspectRatio(1_200.0 / 800.0, contentMode: .fit)
        }
    }

    private func loadPreview() async {
        status = nil
        await Task.yield()
        guard !Task.isCancelled else { return }
        preview = try? CodeStatsExportRenderer.image(snapshot: snapshot, card: card, scale: 1)
    }

    private func report(_ message: String, failed: Bool) {
        self.failed = failed
        status = message
    }

    private func copyImage() {
        do {
            let data = try CodeStatsExportRenderer.pngData(snapshot: snapshot, card: card, scale: 2)
            try UsageShareDelivery.copy(data)
            report("Image copied", failed: false)
        } catch {
            report(error.localizedDescription, failed: true)
        }
    }

    private func saveImage() {
        let selected = card
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = selected.filenameStem + ".png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try CodeStatsExportRenderer.pngData(
                        snapshot: snapshot, card: selected, scale: 2)
                    try UsageShareDelivery.write(data, to: url)
                    report("Saved to \(url.lastPathComponent)", failed: false)
                } catch {
                    report(error.localizedDescription, failed: true)
                }
            }
        }
    }
}
