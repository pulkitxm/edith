import AppKit
import EdithKit
import EdithStudio
import Observation
import SwiftUI

@MainActor
@Observable
final class StudioPreviewModel {
    var before: CGImage?
    var after: CGImage?
    var failure: String?
    var isRendering = false
    private var previewTask: Task<Void, Never>?

    func refresh(
        tool: StudioTool, input: URL, settings: StudioSettings, environment: StudioEnvironment
    ) {
        previewTask?.cancel()
        isRendering = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                await StudioPreviewWork.render(
                    tool, input: input, settings: settings, environment: environment)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isRendering = false
            switch outcome {
            case let .success(preview):
                self.before = preview.before
                self.after = preview.after
                self.failure = nil
            case let .failure(error):
                self.failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        previewTask?.cancel()
        previewTask = nil
        isRendering = false
    }
}

enum StudioPreviewWork {
    static func render(
        _ tool: StudioTool, input: URL, settings: StudioSettings, environment: StudioEnvironment
    ) async -> Result<StudioPreviewImage, Error> {
        do {
            return .success(
                try await StudioPreview.render(
                    tool: tool, input: input, settings: settings, environment: environment))
        } catch {
            return .failure(error)
        }
    }
}

struct StudioPreviewKey: Hashable {
    let input: URL
    let settings: StudioSettings
}

struct StudioPreviewPanel: View {
    let job: StudioJob
    let environment: StudioEnvironment
    @Environment(\.colorScheme) private var scheme

    private var preview: StudioPreviewModel { job.preview }

    var body: some View {
        if let input = job.inputs.first {
            StudioCard {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    HStack {
                        Text("Preview")
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                        Text(input.lastPathComponent)
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if preview.isRendering {
                            ProgressView().controlSize(.small)
                        }
                    }
                    HStack(spacing: UIScale.pt(12)) {
                        pane("Before", preview.before)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        pane("After", preview.after)
                    }
                    .frame(height: UIScale.pt(230))
                    if let failure = preview.failure {
                        Text(failure)
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.warn)
                    }
                }
            }
            .task(id: StudioPreviewKey(input: input, settings: job.settings)) {
                preview.refresh(
                    tool: job.tool, input: input, settings: job.settings, environment: environment)
            }
            .onDisappear { preview.cancel() }
        }
    }

    private func pane(_ title: String, _ image: CGImage?) -> some View {
        VStack(spacing: UIScale.pt(6)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .fill(DashSkin.grid(scheme == .dark))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(UIScale.pt(8))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
            }
            Text(title.uppercased())
                .font(DashSkin.mono(9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
