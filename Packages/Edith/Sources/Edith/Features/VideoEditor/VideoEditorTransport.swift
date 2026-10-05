import AVFoundation
import EdithKit
import SwiftUI

struct VideoEditorTransport: View {
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: UIScale.pt(14)) {
            Button {
                model.seek(to: model.playhead - frameDuration)
            } label: {
                Image(systemName: "backward.frame")
            }
            Button(action: model.togglePlayback) {
                Image(systemName: model.player.rate == 0 ? "play.fill" : "pause.fill")
                    .frame(width: UIScale.pt(30))
            }
            .help("Play or pause (Space)")
            Button {
                model.seek(to: model.playhead + frameDuration)
            } label: {
                Image(systemName: "forward.frame")
            }
            Button {
                model.loopPlayback.toggle()
            } label: {
                Image(systemName: model.loopPlayback ? "repeat.circle.fill" : "repeat")
            }
            .disabled(model.pipeline == nil)
            .help("Loop playback")
            Text(timestamp(model.playhead))
                .font(.edithText(.caption, design: .monospaced))
                .frame(width: UIScale.pt(65), alignment: .trailing)
            Slider(
                value: Binding(
                    get: { min(model.playhead, model.duration) },
                    set: { model.seek(to: $0) }
                ), in: 0...max(0.001, model.duration)
            )
            .disabled(model.duration <= 0)
            Text(timestamp(model.duration))
                .font(.edithText(.caption, design: .monospaced))
                .frame(width: UIScale.pt(65), alignment: .leading)
        }
        .buttonStyle(.edith(.borderless))
        .padding(.horizontal, UIScale.pt(22))
        .frame(height: UIScale.pt(42))
    }

    private var frameDuration: Double {
        model.project?.frameDuration.seconds ?? 1.0 / 60
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
