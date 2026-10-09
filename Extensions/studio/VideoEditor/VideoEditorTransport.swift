import AVFoundation
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct VideoEditorTransport: View {
    let model: VideoEditorModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(14)) {
                playbackControls.fixedSize()
                seekControls.frame(minWidth: UIScale.pt(180))
            }
            VStack(spacing: UIScale.pt(8)) {
                playbackControls.fixedSize()
                seekControls
            }
        }
        .buttonStyle(.edith(.iconOnly))
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(8))
    }

    private var playbackControls: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button {
                model.seek(to: model.playhead - frameDuration)
            } label: {
                Image(systemName: "backward.frame")
            }
            .accessibilityLabel("Previous frame").help("Previous frame")
            Button(action: model.togglePlayback) {
                Image(systemName: model.player.rate == 0 ? "play.fill" : "pause.fill")
                    .frame(width: UIScale.pt(30))
            }
            .accessibilityLabel("Play or pause").help("Play or pause (Space)")
            Button {
                model.seek(to: model.playhead + frameDuration)
            } label: {
                Image(systemName: "forward.frame")
            }
            .accessibilityLabel("Next frame").help("Next frame")
            Button {
                model.loopPlayback.toggle()
            } label: {
                Image(systemName: model.loopPlayback ? "repeat.circle.fill" : "repeat")
            }
            .disabled(model.pipeline == nil)
            .accessibilityLabel("Loop playback").help("Loop playback")
        }
    }

    private var seekControls: some View {
        HStack(spacing: UIScale.pt(8)) {
            Text(timestamp(model.playhead))
                .font(.edithText(.caption, design: .monospaced)).fixedSize()
            Slider(
                value: Binding(
                    get: { min(model.playhead, model.duration) },
                    set: { model.seek(to: $0) }
                ), in: 0...max(0.001, model.duration)
            )
            .disabled(model.duration <= 0).accessibilityLabel("Playback position")
            Text(timestamp(model.duration))
                .font(.edithText(.caption, design: .monospaced)).fixedSize()
        }
    }

    private var frameDuration: Double {
        model.project?.frameDuration.seconds ?? 1.0 / 60
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
