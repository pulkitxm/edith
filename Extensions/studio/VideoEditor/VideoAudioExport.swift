import AppKit
import UniformTypeIdentifiers

extension VideoEditorModel {
    func exportAudio(settings: VideoAudioDeliverySettings) {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: settings.container.rawValue) ?? .audio
        ]
        panel.nameFieldStringValue = "\(project.title).\(settings.container.rawValue)"
        let chosen: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard !project.protectsMedia(at: url) else {
                self.errorMessage = "Choose an audio destination different from your source media."
                return
            }
            if self.exportRemoteAudio(to: url, settings: settings) { return }
            VideoExporter.shared.start(to: url) { progress in
                let pipeline = try await VideoRenderPipeline.make(project: project)
                let report = try await pipeline.exportAudio(
                    to: url, settings: settings, overwrite: true, progress: progress)
                await MainActor.run { VideoExporter.shared.setAudioReport(report, for: url) }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }
}
