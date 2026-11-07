import EdithExtensionUI
import SwiftUI

struct StudioSettingsRows: View {
    let model: StudioModel

    var body: some View {
        Section("Studio") {
            Text(
                "Drop images, PDFs, videos and audio into Studio to edit, compress, convert, merge, split, redact, sign and more. Video and audio tools use FFmpeg."
            )
            .settingsCaption()
            StudioDestinationPicker(model: model)
            Button("Open Studio") { model.facade?.openSettingsStudio() }
                .buttonStyle(.edithDefault)
        }
        .disabled(model.isStopped || model.facade?.state == nil)
        .opacity(model.isStopped ? 0.5 : 1)
    }
}

struct StudioSettingsScene: View {
    let model: StudioModel

    var body: some View {
        Form {
            StudioSettingsRows(model: model)
            if let failure = model.message {
                Section {
                    Text(failure).settingsCaption()
                    Button("Retry") { model.facade?.refresh() }
                        .buttonStyle(.edithDefault)
                }
            }
        }
        .edithForm()
        .pageRefresh(interval: { .seconds(1) }) { model.facade?.refresh() }
    }
}
