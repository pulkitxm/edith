import SwiftUI

struct VideoFrameSamplingPicker: View {
    let model: VideoEditorModel
    let clip: VideoProject.Clip
    @State private var requestedMode: VideoFrameSampling?

    var body: some View {
        Picker(
            "Frame sampling",
            selection: Binding(
                get: { (try? clip.frameSampling) ?? .hold },
                set: { requestedMode = $0 })
        ) {
            Text("Hold").tag(VideoFrameSampling.hold)
            Text("Nearest").tag(VideoFrameSampling.nearest)
        }
        .disabled(requestedMode != nil)
        .help(
            "Nearest rounds post-seek video timestamps onto the output frame grid without changing trim bounds or audio timing."
        )
        .task(id: requestedMode) {
            guard let requestedMode else { return }
            defer { self.requestedMode = nil }
            do {
                try await model.setFrameSampling(requestedMode, clipID: clip.id)
            } catch is CancellationError {
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
