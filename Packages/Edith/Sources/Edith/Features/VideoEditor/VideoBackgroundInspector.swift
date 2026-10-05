import SwiftUI

struct VideoBackgroundInspector: View {
    let background: VideoBackground?
    let update: (VideoBackground?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle(
                "Original-image background",
                isOn: Binding(
                    get: { background != nil },
                    set: { update($0 ? VideoBackground() : nil) }))
            if let background {
                Text("Uses the original, independently of foreground crop and motion.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Background framing").font(.caption).foregroundStyle(.secondary)
                Picker(
                    "Background framing",
                    selection: Binding(
                        get: { background.framing },
                        set: { value in change { $0.framing = value } })
                ) {
                    Text("Fit").tag(VideoVisualEffects.Framing.fit)
                    Text("Fill").tag(VideoVisualEffects.Framing.fill)
                    Text("Full width").tag(VideoVisualEffects.Framing.fullWidth)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                value("Background focal X", \.focalX)
                value("Background focal Y", \.focalY)
                value("Blur radius (canvas px)", \.blurRadius)
                Toggle(
                    "Crop background original",
                    isOn: Binding(
                        get: { background.sourceCrop != nil },
                        set: { enabled in
                            change {
                                $0.sourceCrop =
                                    enabled
                                    ? .init(x: 0, y: 0, width: 1, height: 1) : nil
                            }
                        }))
                if background.sourceCrop != nil {
                    crop("Left", \.x)
                    crop("Top", \.y)
                    crop("Width", \.width)
                    crop("Height", \.height)
                }
            }
        }
    }

    private func change(_ body: (inout VideoBackground) -> Void) {
        var next = background ?? VideoBackground()
        body(&next)
        update(next)
    }

    private func value(_ title: String, _ key: WritableKeyPath<VideoBackground, Double>)
        -> some View
    {
        HStack {
            Text(title)
            TextField(
                title,
                value: Binding(
                    get: { (background ?? VideoBackground())[keyPath: key] },
                    set: { value in change { $0[keyPath: key] = value } }), format: .number
            ).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }

    private func crop(_ title: String, _ key: WritableKeyPath<VideoBackground.Crop, Double>)
        -> some View
    {
        HStack {
            Text(title)
            TextField(
                title,
                value: Binding(
                    get: { background?.sourceCrop?[keyPath: key] ?? 0 },
                    set: { value in change { $0.sourceCrop?[keyPath: key] = value } }),
                format: .number
            ).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }
}
