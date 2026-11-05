import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@available(macOS 14.4, *)
@MainActor
struct AudioMixerPage: View {
    let engine: any AudioMixerPresenting

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Audio Mixer", subtitle: "Set the volume of each app that is playing sound.",
                divider: true)
        } content: {
            AudioMixerView(engine: engine)
        }
    }
}

@available(macOS 14.4, *)
@MainActor
struct AudioMixerView: View {
    @State private var engine: any AudioMixerPresenting
    private let monitorsWhileVisible: Bool
    private let notch: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.compactLayout) private var compact

    init(engine: any AudioMixerPresenting, monitorsWhileVisible: Bool = true, notch: Bool = false) {
        self.monitorsWhileVisible = monitorsWhileVisible
        self.notch = notch
        _engine = State(initialValue: engine)
    }

    private var loading: Bool {
        !engine.loaded && engine.apps.isEmpty && engine.errorMessage == nil
    }

    var body: some View {
        Group {
            if notch {
                notchContent
            } else {
                pageContent
            }
        }
        .onAppear { if monitorsWhileVisible { engine.viewAppeared() } }
        .onDisappear { if monitorsWhileVisible { engine.viewDisappeared() } }
    }

    @ViewBuilder private var pageContent: some View {
        if loading {
            ScrollView {
                PageCard { VStack(spacing: 0) { ForEach(0..<3, id: \.self) { skeletonRow($0) } } }
                    .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    .pageContent(compact, width: .readable)
            }
            .accessibilityLabel("Loading apps that are playing sound")
        } else if engine.apps.isEmpty, engine.errorMessage == nil {
            PageEmptyState(
                symbolName: "speaker.wave.2",
                title: "Nothing is playing sound right now",
                message:
                    "Apps show up here while they make sound. Start music or a video, then set each app's volume separately.",
                footnote: "Setting an app back to 100% restores its normal volume.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    if let error = engine.errorMessage {
                        PageNotice(error, title: "Volume could not be changed", tone: .warning) {
                            EmptyView()
                        } actions: {
                            Button("Try again") { engine.retry() }
                            Button("Open Privacy Settings") { openPrivacySettings() }
                        }
                    }
                    if !engine.apps.isEmpty {
                        PageCard {
                            VStack(spacing: 0) {
                                ForEach(Array(engine.apps.enumerated()), id: \.element.id) {
                                    index, app in
                                    if index > 0 { Divider() }
                                    pageRow(app)
                                }
                            }
                        }
                    }
                }
                .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                .pageContent(compact, width: .readable)
            }
        }
    }

    private func skeletonRow(_ index: Int) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            SkeletonBlock(width: 24, height: 24)
            SkeletonBlock(width: index == 1 ? 72 : 104, height: 12)
            Spacer(minLength: UIScale.pt(12))
            SkeletonBlock(width: 180, height: 6)
            SkeletonBlock(width: 36, height: 12)
        }
        .frame(height: UIScale.pt(44))
    }

    private func pageRow(_ app: MixerApp) -> some View {
        let muted = app.volume == 0
        return HStack(spacing: UIScale.pt(12)) {
            icon(app, size: 24)
            Text(app.name).font(.edithText(.body)).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: UIScale.pt(compact ? 88 : 140), alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: UIScale.pt(8))
            Slider(value: volume(app), in: 0...1)
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: UIScale.pt(120), maxWidth: UIScale.pt(320))
                .accessibilityLabel("\(app.name) volume")
            Text(muted ? "Muted" : "\(Int((app.volume * 100).rounded()))%")
                .font(.edithText(.callout)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: UIScale.pt(48), alignment: .trailing)
            Button {
                engine.setVolume(app, muted ? 1 : 0)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: UIScale.pt(20))
            }
            .buttonStyle(.edith(.iconOnly))
            .help(muted ? "Restore \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(muted ? "Restore \(app.name)" : "Mute \(app.name)")
        }
        .frame(minHeight: UIScale.pt(44))
    }

    private var notchContent: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let error = engine.errorMessage {
                    notchError(error)
                }
                if loading {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 10) {
                            Circle().fill(.white.opacity(0.1)).frame(width: 22, height: 22)
                            Capsule().fill(.white.opacity(0.1)).frame(width: 80, height: 8)
                            Capsule().fill(.white.opacity(0.08)).frame(height: 4)
                        }
                        .frame(height: 24)
                    }
                    .accessibilityLabel("Loading apps that are playing sound")
                } else if engine.apps.isEmpty, engine.errorMessage == nil {
                    VStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.bottom, 4)
                        Text("Nothing is playing sound right now")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Start music or a video and its volume slider appears here.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    ForEach(engine.apps) { app in
                        notchRow(app)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
        }
        .tint(Color.accentColor)
        .environment(\.colorScheme, .dark)
    }

    private func notchRow(_ app: MixerApp) -> some View {
        HStack(spacing: 10) {
            icon(app, size: 22)
            Text(app.name).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                .frame(width: 88, alignment: .leading)
            Slider(value: volume(app), in: 0...1)
                .labelsHidden()
                .controlSize(.mini)
                .accessibilityLabel("\(app.name) volume")
            Text("\(Int((app.volume * 100).rounded()))")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, alignment: .trailing)
        }
        .frame(height: 24)
    }

    @ViewBuilder private func icon(_ app: MixerApp, size: CGFloat) -> some View {
        let side = notch ? size : UIScale.pt(size)
        if let icon = app.icon {
            Image(nsImage: icon).resizable().frame(width: side, height: side)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: side * 0.8))
                .foregroundStyle(notch ? .white.opacity(0.7) : .secondary)
                .frame(width: side, height: side)
        }
    }

    private func volume(_ app: MixerApp) -> Binding<Double> {
        Binding(get: { Double(app.volume) }, set: { engine.setVolume(app, Float($0)) })
    }

    private func openPrivacySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }

    private func notchError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            HStack(spacing: 12) {
                Button("Try again") { engine.retry() }
                Button("Open Privacy Settings") { openPrivacySettings() }
            }
            .buttonStyle(.edith(.borderless))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AudioMixerSettingsPage: View {
    private var available: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text("Notch, Audio tab").foregroundStyle(.secondary)
                } label: {
                    Text("Where it lives")
                    Text("Open the notch and choose Audio to see one volume slider per app.")
                }
                LabeledContent {
                    Text("Notch Shelf settings").foregroundStyle(.secondary)
                } label: {
                    Text("Turn it on")
                    Text(
                        "Switch on Per-app volume mixer in Notch Shelf settings. macOS asks for audio access the first time."
                    )
                }
                LabeledContent {
                    Text("ed audio").font(.edithText(.body).monospaced()).foregroundStyle(
                        .secondary
                    )
                    .textSelection(.enabled)
                } label: {
                    Text("From the terminal")
                    Text("ed audio ls lists apps, and ed audio volume Music 40 sets one.")
                }
            } header: {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if !available {
                        PageNotice(
                            "Per-app volume needs macOS 14.4 or later, so it is unavailable on this Mac.",
                            title: "Not available on this Mac", tone: .warning)
                    }
                    Text("How it works")
                }
            }
        }
        .edithForm()
    }
}
